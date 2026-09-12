"""Runtime: owns the asyncio loop, both servers, config watching and the engine.

The menu bar wraps this; `phice run --headless` uses it directly.
"""
from __future__ import annotations

import asyncio
import json
import logging
import logging.handlers
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from .calibrate import Calibration, fit, write_session
from .certs import (
    CertError,
    CertPaths,
    ca_der,
    ca_mobileconfig,
    cert_covers,
    ensure_server_cert,
    ensure_tailscale_cert,
    local_hostname,
    local_ipv4s,
    tailscale_dns_name,
)
from .config import (
    APPEARANCES,
    ConfigError,
    FileWatcher,
    PointerConfig,
    load_layout,
    load_pointer_config,
)
from .cursor_backend import CursorBackend, FakeCursor, accessibility_trusted
from .engine import PointerEngine
from .pairing import PairingManager
from .paths import Paths
from .rtc import RTCTransport
from .server import PhiceServer, ServerState
from .setup_server import CALIBRATE_HTML, SetupServer
from .signaling import SignalingClient, SignalingError, new_pairing_code

log = logging.getLogger("phice")


def setup_logging(paths: Paths, debug: bool = False) -> None:
    paths.logs.mkdir(parents=True, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(paths.logs / "phice.log", maxBytes=1 << 20,
                                                   backupCount=3)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    root = logging.getLogger()
    root.handlers = [handler, logging.StreamHandler()]
    root.setLevel(logging.DEBUG if debug else logging.INFO)


@dataclass
class Status:
    """Thread-safe snapshot the menu bar reads once a second."""

    lock: threading.Lock = field(default_factory=threading.Lock)
    connected: bool = False
    device_name: str = ""
    phase: str = "disconnected"
    accessibility: bool = False
    pair_code: str = ""
    enabled: bool = True
    tls_url: str = ""
    error: str = ""

    def read(self) -> dict:
        with self.lock:
            return dict(connected=self.connected, device_name=self.device_name, phase=self.phase,
                        accessibility=self.accessibility, enabled=self.enabled,
                        pair_code=self.pair_code,
                        tls_url=self.tls_url, error=self.error)

    def update(self, **kw) -> None:
        with self.lock:
            for k, v in kw.items():
                setattr(self, k, v)


class Runtime:
    def __init__(self, paths: Paths, backend: CursorBackend, tls_port: int = 8443,
                 http_port: int = 8080):
        self.paths = paths
        self.backend = backend
        self.tls_port = tls_port
        self.http_port = http_port
        self.status = Status()
        self.host = local_hostname()
        self.cert_paths = CertPaths.under(paths.certs)

        self.config = self._load_config_or_default()
        self.layout = self._load_layout_or_default()
        self.engine = PointerEngine(self.config, backend)
        self.engine.set_roles(self.layout.roles())
        self.pairing = PairingManager(paths.devices_json)
        self.state = ServerState(paths=paths, pairing=self.pairing, engine=self.engine,
                                 layout=self.layout, config=self.config)
        self.server = PhiceServer(self.state, "0.0.0.0", tls_port, self.host,
                                  extra_origin_hosts=self._extra_origin_hosts)
        self.setup = SetupServer(http_port, lambda: ca_der(self.cert_paths), self._urls,
                                 debug_cursor=self._debug_cursor,
                                 ca_mobileconfig=lambda: ca_mobileconfig(self.cert_paths),
                                 grant_accessibility=lambda: accessibility_trusted(prompt=True),
                                 pair_code=lambda: self.status.read()["pair_code"],
                                 panel_css=lambda: self.paths.panel_css.read_bytes(),
                                 new_code=self.new_pair_code,
                                 set_appearance=self.set_appearance,
                                 request_panel=self.request_panel,
                                 calibrate_html=lambda: CALIBRATE_HTML.encode(),
                                 calibrate_css=lambda: self.paths.calibrate_css.read_bytes(),
                                 calibration_state=self.calibration_state,
                                 start_calibration=self.start_calibration,
                                 apply_calibration=self.apply_calibration,
                                 signaling_url=lambda: self.config.signaling_url)
        self.tailnet: str | None = None  # set in _main when cert_mode is "tailscale"
        self.rtc: RTCTransport | None = None
        self._pair_code: str = ""
        self._answer_wait: asyncio.Task | None = None
        self._rotate = False   # distinguishes "new code" from shutdown
        self._panel_requested = False
        self._panel_url: str | None = None
        self.calibration: Calibration | None = None
        self.rtc_ice_servers: tuple[str, ...] | None = None  # None = the default STUN
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._watcher = FileWatcher([paths.pointer_json, paths.layout_json, paths.theme_css])

    # ----- config -----------------------------------------------------------

    def _load_config_or_default(self) -> PointerConfig:
        try:
            return load_pointer_config(self.paths.pointer_json)
        except ConfigError as e:
            log.error("pointer.json invalid, using defaults: %s", e)
            return PointerConfig()

    def _load_layout_or_default(self):
        from .config import parse_layout
        try:
            return load_layout(self.paths.layout_json)
        except ConfigError as e:
            log.error("layout.json invalid, using defaults: %s", e)
            return parse_layout({"version": 1, "buttons": [
                {"id": "power", "role": "power", "x": 32, "y": 3, "w": 36, "h": 9, "label": "POWER"},
                {"id": "left", "role": "left", "x": 3, "y": 50, "w": 42, "h": 46, "label": "L"},
                {"id": "scroll", "role": "scroll", "x": 46, "y": 48, "w": 8, "h": 50},
                {"id": "right", "role": "right", "x": 55, "y": 50, "w": 42, "h": 46, "label": "R"}]})

    async def _watch_config(self) -> None:
        while True:
            await asyncio.sleep(1.0)
            try:
                changed = await asyncio.to_thread(self._watcher.changed)
            except Exception:
                continue
            for path in changed:
                if path == self.paths.pointer_json:
                    await self._apply_pointer(path)
                elif path == self.paths.layout_json:
                    await self._apply_layout(path)
                elif path == self.paths.theme_css:
                    await self._apply_theme(path)

    async def _apply_pointer(self, path: Path) -> None:
        try:
            cfg = load_pointer_config(path)
        except ConfigError as e:
            log.error("pointer.json rejected: %s", e)
            self.status.update(error=str(e))
            return
        self.config = cfg
        self.state.config = cfg
        self.engine.set_config(cfg)
        self.status.update(error="")
        log.info("pointer.json reloaded")
        await self.server._send_state()
        if self.rtc:
            # Editing config while on the WebRTC transport used to reach the
            # engine but never the phone, so appearance and recentre timing
            # silently disagreed until the next reconnect.
            self.rtc.notify_state()

    async def _apply_layout(self, path: Path) -> None:
        try:
            layout = load_layout(path)
        except ConfigError as e:
            log.error("layout.json rejected: %s", e)
            self.status.update(error=str(e))
            return
        self.layout = layout
        self.status.update(error="")
        log.info("layout.json reloaded")
        await self.server.push_layout(layout)
        if self.rtc:
            await self.rtc.push_layout(path.read_text())

    async def _apply_theme(self, path: Path) -> None:
        log.info("theme.css reloaded")
        await self.server.push_theme_changed()
        if self.rtc:
            await self.rtc.push_theme(path.read_text())

    # ----- urls -------------------------------------------------------------

    def _extra_origin_hosts(self) -> list[str]:
        """Names beyond <host>.local that the page may legitimately be loaded from."""
        hosts = local_ipv4s()
        if self.tailnet:
            hosts.append(self.tailnet)
        return hosts

    def _urls(self) -> tuple[str, str, bool, str | None, str | None]:
        """(ca, pair, show_ca, ca_alt, pair_alt) -- primaries first, notes after.

        On a tailnet the certificate is publicly trusted, so there is nothing to
        install: one URL, no CA card, and it works from cellular because the
        phone and Mac are peers on the tailnet rather than the local subnet.
        Otherwise the IP form is primary, because .local needs mDNS and many
        networks block it, and .local is demoted to a note.
        """
        token = self.pairing.mint_pairing_token()
        if self.tailnet:
            return (f"https://{self.tailnet}:{self.server.port}/",
                    f"https://{self.tailnet}:{self.server.port}/?pair={token}",
                    False, None, None)
        local_ca = f"http://{self.host}.local:{self.setup.port}/ca.mobileconfig"
        local_pair = f"https://{self.host}.local:{self.server.port}/?pair={token}"
        ip = next(iter(local_ipv4s()), None)
        if not ip:
            return local_ca, local_pair, self.config.cert_mode == "auto", None, None
        ca = f"http://{ip}:{self.setup.port}/ca.mobileconfig"
        pair = f"https://{ip}:{self.server.port}/?pair={token}"
        return ca, pair, self.config.cert_mode == "auto", local_ca, local_pair

    def _debug_cursor(self) -> dict:
        """Loopback-only snapshot. The menu bar is the normal way to see this, but
        it can be invisible (a full menu bar on a notched Mac hides new items), and
        then there is otherwise no way to tell why the pointer is not moving."""
        d = dict(self.status.read())
        if self.rtc:
            d["rtc"] = {"frames": self.rtc.frames, "bad": self.rtc.bad_frames,
                        "last_error": self.rtc.last_error,
                        "channel": (self.rtc.channel.readyState
                                    if self.rtc.channel else "none"),
                        "state": self.rtc.pc.connectionState}
        d["appearance"] = self.config.ui.appearance
        d["phone_url"] = f"{self.config.signaling_url}/app"
        d["transport"] = self.config.transport
        d["sensor_hz"] = round(self.rtc.hz if self.rtc and self.rtc.is_open
                               else self.state.sensor_hz, 1)
        d["phone_caps"] = self.state.caps
        d["cert_mode"] = self.config.cert_mode
        d["mapping"] = self.config.mapping
        if isinstance(self.backend, FakeCursor):
            d.update(self.backend.summary())
        else:
            x, y = self.backend.get_position()
            d.update(x=x, y=y)
        d["phase"] = self.engine.phase.value
        return d

    # ----- status -----------------------------------------------------------

    async def _status_loop(self) -> None:
        while True:
            # Either transport can be the live one. Reading only state.client
            # reported "not connected" through an entire working WebRTC session,
            # which sent every diagnosis down the wrong path.
            rtc_open = self.rtc is not None and self.rtc.is_open
            self.status.update(connected=rtc_open or self.state.client is not None,
                               device_name=(self.rtc.client_name if rtc_open
                                            else self.state.client_name),
                               phase=self.engine.phase.value)
            # Poll here rather than relying on the menu bar, which may never appear.
            if not isinstance(self.backend, FakeCursor):
                self.set_accessibility(accessibility_trusted())
            await asyncio.sleep(0.5)

    def _dispatch(self, coro) -> bool:
        """Hand a coroutine to the loop thread, or discard it if that loop is gone.

        The menu bar outlives the runtime thread, so it can still call in after
        the loop has closed. Without this the call raises on every tick and
        leaves the coroutine un-awaited.
        """
        if self._loop is None or self._loop.is_closed():
            coro.close()
            return False
        asyncio.run_coroutine_threadsafe(coro, self._loop)
        return True

    def set_accessibility(self, ok: bool) -> None:
        # Keep the reported status in step unconditionally: ServerState defaults to
        # True and Status to False, so gating the whole update on a change left the
        # status stuck at False even while the permission was granted.
        changed = ok != self.state.accessibility
        self.state.accessibility = ok
        self.status.update(accessibility=ok)
        if changed:
            self._dispatch(self.server._send_state())

    def set_enabled(self, enabled: bool) -> None:
        self.engine.set_enabled(enabled)
        self.status.update(enabled=enabled)

    def force_reload(self) -> None:
        """Menu action: re-read every config file regardless of mtime."""
        self._watcher = FileWatcher([])  # forget mtimes so the next poll reloads everything
        for path, applier in ((self.paths.pointer_json, self._apply_pointer),
                              (self.paths.layout_json, self._apply_layout),
                              (self.paths.theme_css, self._apply_theme)):
            if self._loop:
                asyncio.run_coroutine_threadsafe(applier(path), self._loop)
        self._watcher = FileWatcher([self.paths.pointer_json, self.paths.layout_json,
                                     self.paths.theme_css])

    def set_recording(self, on: bool) -> Path | None:
        if not on:
            rec = self.state.recorder
            self.state.recorder = None
            if rec is not None:
                try:
                    rec.close()
                except Exception:
                    pass
            return None
        self.paths.sessions.mkdir(parents=True, exist_ok=True)
        path = self.paths.sessions / (time.strftime("%Y-%m-%dT%H-%M-%S") + ".jsonl")
        self.state.recorder = path.open("w", encoding="utf-8", buffering=1)
        log.info("recording to %s", path)
        return path

    def revoke_devices(self) -> None:
        self.pairing.revoke_all()
        if self.state.client:
            self._dispatch(self.state.client.close(4003, "revoked"))

    # ----- lifecycle --------------------------------------------------------

    def _ice_servers(self) -> tuple | None:
        """Configured ICE servers, or None to use the default STUN.

        A relay matters when both peers sit behind symmetric NAT -- a phone on
        carrier NAT talking to a Mac on a university network cannot hole-punch,
        and STUN alone discovers addresses neither side can reach.
        """
        cfg = self.config.ice_servers
        return tuple(cfg) if cfg else None

    # ----- calibration ------------------------------------------------------

    def start_calibration(self) -> dict:
        """Begin a calibration run and show its window."""
        rect = self.backend.displays()[0] if self.backend.displays() else None
        width = int(rect.w) if rect else 1440
        height = int(rect.h) if rect else 900
        self.calibration = Calibration(width=width, height=height)
        self.engine.on_look = self._calibration_sample
        self.request_panel_url(f"http://127.0.0.1:{self.http_port}/calibrate")
        return {"trials": len(self.calibration.plan), "width": width, "height": height}

    def _calibration_sample(self, now: float, yaw: float, pitch: float) -> None:
        cal = self.calibration
        if cal is None or cal.finished:
            return
        pos = self.backend.get_position()
        if cal.trial is not None and cal._current is None:
            cal.begin(now, pos)
        cal.observe(now, pos, yaw, pitch)
        if cal.finished:
            self.engine.on_look = None

    def calibration_state(self) -> dict:
        cal = self.calibration
        if cal is None:
            return {"running": False}
        state = dict(cal.state(), running=True)
        if cal.finished:
            state["fitted"] = fit(cal.results, json.loads(self.paths.pointer_json.read_text()))
        return state

    def apply_calibration(self) -> dict:
        """Write the fitted settings into pointer.json, keeping the evidence."""
        cal = self.calibration
        if cal is None or not cal.finished:
            return {"ok": False, "error": "calibration has not finished"}
        data = json.loads(self.paths.pointer_json.read_text())
        fitted = fit(cal.results, data)
        if "error" in fitted:
            return {"ok": False, **fitted}
        for key, value in fitted.items():
            if key in ("samples", "evidence"):
                continue
            if key == "one_euro":
                data.setdefault("one_euro", {}).update(value)
            else:
                data[key] = value
        self.paths.pointer_json.write_text(json.dumps(data, indent=2) + "\n")
        write_session(self.paths.sessions / "calibration.json", cal.results, fitted)
        self._dispatch(self._apply_pointer(self.paths.pointer_json))
        return {"ok": True, "fitted": fitted}

    def request_panel_url(self, url: str) -> None:
        self._panel_url = url
        self._panel_requested = True

    def request_panel(self) -> None:
        """Ask for the control panel window. Thread safe by design.

        The window can only be created on the main thread, which the menu bar
        owns, so this only raises a flag; the menu bar's timer picks it up.
        """
        self._panel_requested = True

    def take_panel_request(self) -> str | bool:
        """Returns the url to show, True for the default panel, or False."""
        if not self._panel_requested:
            return False
        self._panel_requested = False
        url, self._panel_url = self._panel_url, None
        return url or True

    def set_appearance(self, value: str) -> bool:
        """Persist the chosen appearance and tell the phone at once.

        It goes into pointer.json rather than staying in memory because the Mac
        is the single source of truth for it: a phone connecting later must get
        the same answer as one already connected, and the choice has to survive
        a restart. Writing the file also routes it through the normal reload
        path, so there is one way config reaches the phone, not two.
        """
        if value not in APPEARANCES:
            return False
        path = self.paths.pointer_json
        data = json.loads(path.read_text())
        data.setdefault("ui", {})["appearance"] = value
        path.write_text(json.dumps(data, indent=2) + "\n")
        self._dispatch(self._apply_pointer(path))
        return True

    def new_pair_code(self) -> None:
        """Drop the current code and republish under a fresh one.

        Cancelling the wait is what actually does it: the publish loop is parked
        in wait_for_answer, and closing the peer connection would not wake it.
        """
        self._pair_code = ""
        task = self._answer_wait
        if task is not None and self._loop is not None and not self._loop.is_closed():
            # Only this path produces a cancellation, so only this path may mark
            # one as expected. Setting the flag unconditionally left it armed and
            # the loop then swallowed a real shutdown.
            self._rotate = True
            self._loop.call_soon_threadsafe(task.cancel)
        elif self.rtc is not None:
            # Already paired: there is no wait to cancel, so end the session and
            # let the loop publish a fresh offer. Without this the button looked
            # dead for exactly the user who needs it -- one whose phone is stuck.
            self._dispatch(self.rtc.close())

    async def start_webrtc(self) -> None:
        """Publish an offer under a short code and wait for a phone to answer.

        Loops: a pairing code is single use, so once a phone connects the next one
        needs a fresh offer. No certificate is involved at any point -- WebRTC
        verifies the peers by DTLS fingerprint, which is the whole reason this
        transport exists.
        """
        client = SignalingClient(self.config.signaling_url)
        while True:
            ice = self._ice_servers()
            if ice is None:
                # Take the relay from the signaling service so both peers get the
                # same one. Credentials are short-lived and never stored here.
                fetched = await client.fetch_ice_servers()
                if fetched:
                    ice = tuple(fetched)
                    if any("turn:" in str(s.get("urls", "")) for s in fetched):
                        log.info("using a relay from the signaling service")
                    else:
                        log.warning("no TURN relay available; this will only connect "
                                    "when both devices are on the same network")
            self.rtc = RTCTransport(engine=self.engine,
                                    layout_json=self.paths.layout_json.read_text(),
                                    theme_css=self.paths.theme_css.read_text(),
                                    accessibility=lambda: self.status.read()["accessibility"],
                                    ice_servers=(self.rtc_ice_servers
                                                 if self.rtc_ice_servers is not None
                                                 else ice))
            offer = await self.rtc.create_offer()
            # Keep the same code for the life of the process and republish a fresh
            # offer under it. Minting a new one after every disconnect meant the
            # user had to walk back to the Mac each time -- and the page's
            # remembered code was always the dead one.
            code = self._pair_code or new_pairing_code()
            self._pair_code = code
            try:
                await client.publish_offer(code, offer)
            except SignalingError as e:
                log.error("could not reach the pairing service: %s", e)
                self.status.update(error=str(e))
                await self.rtc.close()
                await asyncio.sleep(10)
                continue
            self.status.update(pair_code=code, error="")
            log.info("pairing code %s -- enter it at %s/app", code, self.config.signaling_url)
            self._answer_wait = asyncio.ensure_future(client.wait_for_answer(code))
            try:
                answer = await self._answer_wait
            except SignalingError:
                await self.rtc.close()
                continue            # the code expired unused; mint another
            except asyncio.CancelledError:
                # Two very different things arrive here: the panel asking for a
                # new code, and this whole task being shut down. Swallowing both
                # made the loop immortal -- the app could not quit and the test
                # suite hung at random.
                await self.rtc.close()
                if not self._rotate:
                    raise
                self._rotate = False
                continue
            finally:
                self._answer_wait = None
                self._rotate = False   # never let a stale request eat a shutdown
            await self.rtc.accept_answer(answer)
            while self.rtc.pc.connectionState not in ("failed", "closed", "disconnected"):
                await asyncio.sleep(1.0)
            await self.rtc.close()

    async def _main(self) -> None:
        if self.config.transport == "webrtc":
            self.http_port = await asyncio.to_thread(self.setup.start)
            log.info("webrtc transport; pairing code at http://127.0.0.1:%d/pair",
                     self.http_port)
            await asyncio.gather(self.start_webrtc(), self._watch_config(), self._status_loop())
            return
        if self.config.cert_mode == "tailscale":
            # Prefer the name recorded by `phice tailscale`. The GUI app's CLI
            # cannot be reached from the launch agent (no GUI bootstrap
            # namespace), so resolving it live would fail exactly where the
            # service actually runs.
            self.tailnet = self.config.tailscale_host or tailscale_dns_name()
            if not self.tailnet:
                raise CertError("cert_mode is 'tailscale' but no tailnet name is known; "
                                "run 'phice tailscale' from a terminal")
            try:
                if ensure_tailscale_cert(self.cert_paths, self.tailnet):
                    log.info("issued a trusted certificate for %s", self.tailnet)
            except CertError as e:
                # A tailnet certificate is good for 90 days. If it cannot be
                # renewed right now, keep serving the valid one rather than
                # refusing to start.
                if not cert_covers(self.cert_paths.server_crt, self.tailnet):
                    raise
                log.warning("could not refresh the tailnet certificate (%s); "
                            "serving the existing one", e)
        elif self.config.cert_mode == "auto":
            if ensure_server_cert(self.cert_paths, self.host):
                log.info("issued a new server certificate for %s.local", self.host)
        if self.tailnet:
            self.server.tls_host = self.tailnet
        self.tls_port = await self.server.start()
        self.http_port = await asyncio.to_thread(self.setup.start)
        name = self.tailnet or f"{self.host}.local"
        self.status.update(tls_url=f"https://{name}:{self.tls_port}/")
        log.info("listening: https://%s:%d  setup: http://127.0.0.1:%d/setup",
                 name, self.tls_port, self.http_port)
        await asyncio.gather(self._watch_config(), self._status_loop())

    def start_background(self) -> None:
        """Run the loop on a worker thread so AppKit can own the main thread."""
        def run():
            loop = asyncio.new_event_loop()
            self._loop = loop
            asyncio.set_event_loop(loop)
            try:
                loop.run_until_complete(self._main())
            except asyncio.CancelledError:
                pass
            except Exception as e:
                log.exception("runtime stopped")
                self.status.update(error=f"{type(e).__name__}: {e}")
            finally:
                loop.close()

        self._thread = threading.Thread(target=run, daemon=True, name="phice-loop")
        self._thread.start()

    def stop(self) -> None:
        self.engine.disconnected()
        self.setup.stop()
        self._dispatch(self.server.stop())

    def run_forever(self) -> None:
        asyncio.run(self._main())
