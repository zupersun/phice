"""Runtime: owns the asyncio loop, the control server, config watching and the engine.

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
from datetime import datetime
from pathlib import Path

from . import calibrate, signaling
from .config import (
    APPEARANCES,
    ConfigError,
    FileWatcher,
    Layout,
    PointerConfig,
    load_layout,
    load_pointer_config,
    parse_layout,
)
from .control import ControlServer
from .cursor_backend import CursorBackend, FakeCursor, accessibility_trusted
from .engine import PointerEngine
from .paths import Paths, client_version
from .rtc import RTCTransport

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
    """Thread-safe snapshot the menu bar and the panel read once a second."""

    lock: threading.Lock = field(default_factory=threading.Lock)
    connected: bool = False
    device_name: str = ""
    phase: str = "disconnected"
    accessibility: bool = False
    pair_code: str = ""
    enabled: bool = True
    error: str = ""
    #: Set while the letterbox cannot be reached. Separate from `error`, which is
    #: about the config files: the panel and the menu bar say different things.
    pairing_error: str = ""

    def read(self) -> dict:
        with self.lock:
            return dict(connected=self.connected, device_name=self.device_name, phase=self.phase,
                        accessibility=self.accessibility, enabled=self.enabled,
                        pair_code=self.pair_code, error=self.error,
                        pairing_error=self.pairing_error)

    def update(self, **kw) -> None:
        with self.lock:
            for k, v in kw.items():
                setattr(self, k, v)


class Runtime:
    def __init__(self, paths: Paths, backend: CursorBackend, http_port: int = 8080):
        self.paths = paths
        self.backend = backend
        self.http_port = http_port
        self.status = Status()

        self.config = self._load_config_or_default()
        self.layout = self._load_layout_or_default()
        self.engine = PointerEngine(self.config, backend)
        self.engine.set_roles(self.layout.roles())
        self.pairing = signaling.Pairing()
        self.rtc: RTCTransport | None = None
        self.rtc_ice_servers: tuple[str, ...] | None = None  # None = the default STUN
        self.recorder = None                                 # an open text file while recording
        self.calibration = calibrate.Runner(
            paths, backend, self.engine,
            show=lambda: self.request_panel_url(
                f"http://127.0.0.1:{self.http_port}/calibrate", fullscreen=True))
        self.control = ControlServer(
            http_port,
            pages={"/panel.css": paths.panel_css.read_bytes,
                   "/calibrate.css": paths.calibrate_css.read_bytes},
            actions={"/debug/cursor": self._debug_cursor,
                     # Prompting from this process is what makes macOS list *this*
                     # binary; asking from a terminal would add the terminal.
                     "/debug/grant": lambda: {"accessibility": accessibility_trusted(prompt=True)},
                     "/debug/panel": self.request_panel,
                     "/debug/newcode": self.new_pair_code,
                     "/calibrate/state": self.calibration_state,
                     "/calibrate/start": self.start_calibration,
                     "/calibrate/begin": self.calibration.begin,
                     "/calibrate/apply": self.apply_calibration,
                     "/calibrate/cancel": self.cancel_calibration},
            settings={"/debug/layout": self.set_layout,
                      "/debug/appearance": self.set_appearance})
        self._panel_requested = False
        self._panel_url: tuple[str, bool] | None = None
        self._close_calibration = False
        self._last_logged_phase = "disconnected"
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._watcher = FileWatcher(self._watched())

    def _watched(self) -> list[Path]:
        """Editing the active preset must reload it, not only layout.json."""
        files = [self.paths.pointer_json, self.paths.layout_json, self.paths.theme_css]
        active = self.active_layout_path()
        if active not in files:
            files.append(active)
        return files

    # ----- config -----------------------------------------------------------

    def _load_config_or_default(self) -> PointerConfig:
        try:
            return load_pointer_config(self.paths.pointer_json)
        except ConfigError as e:
            log.error("pointer.json invalid, using defaults: %s", e)
            return PointerConfig()

    def active_layout_path(self) -> Path:
        """Which layout file is in force.

        A named preset wins; anything else falls back to layout.json, which is
        what every install before presets existed had. A layout that fails to
        load would leave the phone with no buttons at all -- indistinguishable
        from a broken app -- so falling back is always better than failing.
        """
        name = self.config.ui.layout
        if not name:
            return self.paths.layout_json
        preset = self.paths.layouts / f"{name}.json"
        if preset.exists():
            return preset
        log.error("ui.layout names %r but %s does not exist; using layout.json",
                  name, preset)
        return self.paths.layout_json

    def _load_layout_or_default(self) -> Layout:
        chosen = self.active_layout_path()
        try:
            return load_layout(chosen)
        except ConfigError as e:
            log.error("%s invalid: %s", chosen.name, e)
            if chosen != self.paths.layout_json:
                try:
                    return load_layout(self.paths.layout_json)
                except ConfigError:
                    pass
            log.error("using the built-in layout")
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
                elif path == self.paths.layout_json or path.parent == self.paths.layouts:
                    await self._apply_layout(self.active_layout_path())
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
        self.engine.set_config(cfg)
        self.status.update(error="")
        log.info("pointer.json reloaded")
        # ui.layout may have changed, which changes both the layout in force and
        # which file we should be watching.
        await self._apply_layout(self.active_layout_path())
        self._watcher = FileWatcher(self._watched())
        # Appearance and recentre timing travel in the state message, so the
        # phone must hear about an edit at once rather than at the next reconnect.
        await self._push_state()

    async def _apply_layout(self, path: Path) -> None:
        try:
            layout = load_layout(path)
        except ConfigError as e:
            log.error("%s rejected: %s", path.name, e)
            self.status.update(error=str(e))
            return
        self.layout = layout
        self.engine.set_roles(layout.roles())
        self.status.update(error="")
        log.info("%s reloaded", path.name)
        if self.rtc:
            await self.rtc.push_layout(layout.to_dict())

    async def _apply_theme(self, path: Path) -> None:
        log.info("theme.css reloaded")
        if self.rtc:
            await self.rtc.push_theme(path.read_text())

    async def _push_state(self) -> None:
        if self.rtc:
            self.rtc.notify_state()

    # ----- status -----------------------------------------------------------

    def _debug_cursor(self) -> dict:
        """Loopback-only snapshot. The menu bar is the normal way to see this, but
        it can be invisible (a full menu bar on a notched Mac hides new items), and
        then there is otherwise no way to tell why the pointer is not moving."""
        d = dict(self.status.read())
        rtc = self.rtc
        if rtc:
            d["rtc"] = {"frames": rtc.frames, "bad": rtc.bad_frames,
                        "last_error": rtc.last_error,
                        "channel": rtc.channel.readyState if rtc.channel else "none",
                        "state": rtc.pc.connectionState}
        d["appearance"] = self.config.ui.appearance
        d["layout"] = self.config.ui.layout or "custom"
        d["layouts"] = sorted(p.stem for p in self.paths.layouts.glob("*.json"))
        d["calibrated"] = self._calibrated_when()
        # Both halves of the comparison, not just its verdict: a check that
        # quietly disables itself because one side is empty is worse than no
        # check, and that is exactly what happened.
        d["client_expected"] = client_version()
        d["client_reported"] = rtc.client_caps if rtc else ""
        d["client_stale"] = bool(rtc and rtc.client_stale)
        d["signaling_url"] = self.config.signaling_url
        d["phone_url"] = f"{self.config.signaling_url}/app"
        # True while the letterbox holds this session's offer and nobody has
        # answered it. After a disconnect the previous offer lingers there until
        # the fresh one is gathered and published; answering it fails ICE.
        d["offer_ready"] = self.pairing.waiter is not None
        # The code's remaining life at the letterbox, from the wall clock so a
        # sleep shows as expired rather than paused. The panel draws code_life.
        p = self.pairing
        remaining = max(0.0, p.published_at + p.ttl - time.time()) if p.waiter else 0.0
        d["code_expires_in"] = round(remaining)
        d["code_life"] = round(min(1.0, remaining / p.ttl), 3) if p.ttl else 0.0
        d["sensor_hz"] = round(rtc.hz, 1) if rtc and rtc.is_open else 0.0
        d["mapping"] = self.config.mapping
        if isinstance(self.backend, FakeCursor):
            d.update(self.backend.summary())
        else:
            x, y = self.backend.get_position()
            d.update(x=x, y=y)
        d["phase"] = self.engine.phase.value
        return d

    async def _status_loop(self) -> None:
        while True:
            phase = self.engine.phase.value
            if phase != self._last_logged_phase:
                # Logged on the Mac, so "my button does nothing" can be answered
                # without asking anyone to reload a page: either the press
                # arrives and moves the pointer, or it never arrives at all.
                log.info("pointer %s -> %s", self._last_logged_phase, phase)
                self._last_logged_phase = phase
            rtc = self.rtc
            open_ = rtc is not None and rtc.is_open
            self.status.update(connected=open_, device_name=rtc.client_name if open_ else "",
                               phase=phase)
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
        """`accessibility` gates nothing here; it is reported to the phone."""
        changed = ok != self.status.read()["accessibility"]
        self.status.update(accessibility=ok)
        if changed:
            self._dispatch(self._push_state())

    def set_enabled(self, enabled: bool) -> None:
        self.engine.set_enabled(enabled)
        self.status.update(enabled=enabled)

    def force_reload(self) -> None:
        """Menu action: re-read every config file regardless of mtime."""
        for path, applier in ((self.paths.pointer_json, self._apply_pointer),
                              (self.active_layout_path(), self._apply_layout),
                              (self.paths.theme_css, self._apply_theme)):
            self._dispatch(applier(path))
        self._watcher = FileWatcher(self._watched())

    # ----- recording --------------------------------------------------------

    def set_recording(self, on: bool) -> Path | None:
        if not on:
            rec, self.recorder = self.recorder, None
            if rec is not None:
                try:
                    rec.close()
                except Exception:
                    pass
            return None
        self.paths.sessions.mkdir(parents=True, exist_ok=True)
        path = self.paths.sessions / (time.strftime("%Y-%m-%dT%H-%M-%S") + ".jsonl")
        self.recorder = path.open("w", encoding="utf-8", buffering=1)
        log.info("recording to %s", path)
        return path

    def record(self, raw: str) -> None:
        """One inbound frame, as it arrived. tools/replay.py reads these back."""
        rec = self.recorder
        if rec is None:
            return
        try:
            rec.write(json.dumps({"rx": time.monotonic(), "raw": raw}) + "\n")
        except Exception:
            log.warning("recording stopped", exc_info=True)
            self.recorder = None

    # ----- calibration ------------------------------------------------------

    def start_calibration(self) -> dict:
        return self.calibration.start()

    def _calibrated_when(self) -> str:
        """When calibration last wrote settings, as something readable.

        Read off the saved trials rather than tracked separately: the file is
        the record, and if it is gone the claim would be unsupported anyway.
        """
        record = self.paths.sessions / "calibration.json"
        try:
            when = datetime.fromtimestamp(record.stat().st_mtime)
        except OSError:
            return ""
        days = (datetime.now() - when).days
        if days == 0:
            return when.strftime("today at %H:%M")
        return "yesterday" if days == 1 else f"{days} days ago"

    def calibration_state(self) -> dict:
        """Includes whether there is a phone to calibrate with.

        The window covers the whole display, including the panel that shows the
        pairing code, so it has to carry that itself -- otherwise the only way
        to connect a phone is to close the thing you are trying to use.
        """
        s = self.calibration.state()
        status = self.status.read()
        s["connected"] = status["connected"]
        s["phase"] = status["phase"]
        s["pair_code"] = status["pair_code"]
        s["phone_url"] = f"{self.config.signaling_url}/app"
        s["ready"] = status["connected"] and status["phase"] in ("on", "hold", "held")
        return s

    def apply_calibration(self) -> dict:
        out = self.calibration.apply()
        if out.get("ok"):
            self._dispatch(self._apply_pointer(self.paths.pointer_json))
        return out

    def cancel_calibration(self) -> dict:
        """Abandon the run and take the window off the screen.

        A borderless full-screen window with no title bar has no close button,
        so there must be a way out that does not involve the menu bar."""
        self.calibration.cancel()
        self._close_calibration = True
        return {"ok": True}

    # ----- windows ----------------------------------------------------------

    def request_panel_url(self, url: str, *, fullscreen: bool = False) -> None:
        self._panel_url = (url, fullscreen)
        self._panel_requested = True

    def take_calibration_close(self) -> bool:
        done, self._close_calibration = self._close_calibration, False
        return done

    def request_panel(self) -> None:
        """Ask for the control panel window. Thread safe by design.

        The window can only be created on the main thread, which the menu bar
        owns, so this only raises a flag; the menu bar's timer picks it up.
        """
        self._panel_requested = True

    def take_panel_request(self) -> tuple[str, bool] | bool:
        """(url, fullscreen) to show, True for the default panel, or False."""
        if not self._panel_requested:
            return False
        self._panel_requested = False
        url, self._panel_url = self._panel_url, None
        return url or True

    # ----- settings written from the panel ----------------------------------

    def set_layout(self, value: str) -> bool:
        """Choose a layout preset by name, or "" to go back to layout.json."""
        if "/" in value or ".." in value:
            return False
        if value and not (self.paths.layouts / f"{value}.json").exists():
            return False
        self._write_ui("layout", value)
        return True

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
        self._write_ui("appearance", value)
        return True

    def _write_ui(self, key: str, value: str) -> None:
        path = self.paths.pointer_json
        data = json.loads(path.read_text())
        data.setdefault("ui", {})[key] = value
        path.write_text(json.dumps(data, indent=2) + "\n")
        self._dispatch(self._apply_pointer(path))

    def new_pair_code(self) -> None:
        """Drop the current code and republish under a fresh one.

        Cancelling the wait is what actually does it: the publish loop is parked
        in wait_for_answer, and closing the peer connection would not wake it.
        """
        self.pairing.code = ""
        task = self.pairing.waiter
        if task is not None and self._loop is not None and not self._loop.is_closed():
            # Only this path produces a cancellation, so only this path may mark
            # one as expected. Setting the flag unconditionally left it armed and
            # the loop then swallowed a real shutdown.
            self.pairing.rotate = True
            self._loop.call_soon_threadsafe(task.cancel)
        elif self.rtc is not None:
            # Already paired: there is no wait to cancel, so end the session and
            # let the loop publish a fresh offer. Without this the button looked
            # dead for exactly the user who needs it -- one whose phone is stuck.
            self._dispatch(self.rtc.close())

    # ----- lifecycle --------------------------------------------------------

    async def _main(self) -> None:
        self.http_port = await asyncio.to_thread(self.control.start)
        log.info("control panel at http://127.0.0.1:%d/panel", self.http_port)
        await asyncio.gather(signaling.run(self), self._watch_config(), self._status_loop())

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
        self.control.stop()
        if self.rtc:
            self._dispatch(self.rtc.close())

    def run_forever(self) -> None:
        asyncio.run(self._main())
