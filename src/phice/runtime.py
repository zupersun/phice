"""Runtime: owns the asyncio loop, both servers, config watching and the engine.

The menu bar wraps this; `phice run --headless` uses it directly.
"""
from __future__ import annotations

import asyncio
import logging
import logging.handlers
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from .certs import CertPaths, ca_der, ensure_server_cert, local_hostname
from .config import ConfigError, FileWatcher, PointerConfig, load_layout, load_pointer_config
from .cursor_backend import CursorBackend, FakeCursor
from .engine import PointerEngine
from .pairing import PairingManager
from .paths import Paths
from .server import PhiceServer, ServerState
from .setup_server import SetupServer

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
    enabled: bool = True
    tls_url: str = ""
    error: str = ""

    def read(self) -> dict:
        with self.lock:
            return dict(connected=self.connected, device_name=self.device_name, phase=self.phase,
                        accessibility=self.accessibility, enabled=self.enabled,
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
        self.server = PhiceServer(self.state, "0.0.0.0", tls_port, self.host)
        self.setup = SetupServer(http_port, lambda: ca_der(self.cert_paths), self._urls,
                                 debug_cursor=self._debug_cursor)
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

    async def _apply_theme(self, path: Path) -> None:
        log.info("theme.css reloaded")
        await self.server.push_theme_changed()

    # ----- urls -------------------------------------------------------------

    def _urls(self) -> tuple[str, str, bool]:
        token = self.pairing.mint_pairing_token()
        ca = f"http://{self.host}.local:{self.setup.port}/ca.crt"
        pair = f"https://{self.host}.local:{self.server.port}/?pair={token}"
        return ca, pair, self.config.cert_mode == "auto"

    def _debug_cursor(self) -> dict:
        if isinstance(self.backend, FakeCursor):
            return self.backend.summary()
        x, y = self.backend.get_position()
        return {"x": x, "y": y, "phase": self.engine.phase.value}

    # ----- status -----------------------------------------------------------

    async def _status_loop(self) -> None:
        while True:
            self.status.update(connected=self.state.client is not None,
                               device_name=self.state.client_name,
                               phase=self.engine.phase.value)
            await asyncio.sleep(0.5)

    def set_accessibility(self, ok: bool) -> None:
        if ok != self.state.accessibility:
            self.state.accessibility = ok
            self.status.update(accessibility=ok)
            if self._loop:
                asyncio.run_coroutine_threadsafe(self.server._send_state(), self._loop)

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
        if self._loop and self.state.client:
            asyncio.run_coroutine_threadsafe(self.state.client.close(4003, "revoked"), self._loop)

    # ----- lifecycle --------------------------------------------------------

    async def _main(self) -> None:
        if self.config.cert_mode == "auto":
            if ensure_server_cert(self.cert_paths, self.host):
                log.info("issued a new server certificate for %s.local", self.host)
        self.tls_port = await self.server.start()
        self.http_port = await asyncio.to_thread(self.setup.start)
        self.status.update(tls_url=f"https://{self.host}.local:{self.tls_port}/")
        log.info("listening: https://%s.local:%d  setup: http://127.0.0.1:%d/setup",
                 self.host, self.tls_port, self.http_port)
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
            except Exception:
                log.exception("runtime stopped")
            finally:
                loop.close()

        self._thread = threading.Thread(target=run, daemon=True, name="phice-loop")
        self._thread.start()

    def stop(self) -> None:
        self.engine.disconnected()
        self.setup.stop()
        if self._loop:
            asyncio.run_coroutine_threadsafe(self.server.stop(), self._loop)

    def run_forever(self) -> None:
        asyncio.run(self._main())
