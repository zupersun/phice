"""TLS server: serves the phone page and the WebSocket control channel on one port."""
from __future__ import annotations

import asyncio
import json
import logging
import ssl
import time
from collections.abc import Callable
from dataclasses import dataclass
from http import HTTPStatus
from pathlib import Path

from websockets.asyncio.server import ServerConnection, serve
from websockets.datastructures import Headers
from websockets.http11 import Response

from .certs import CertPaths, san_names
from .config import Layout, PointerConfig
from .engine import PointerEngine
from .pairing import PairingManager
from .paths import WEB_DIR, Paths
from .protocol import (
    Bye,
    Hello,
    Ping,
    ProtocolError,
    SensorPacket,
    err_message,
    layout_message,
    parse_client_message,
    pong_message,
    state_message,
    theme_changed_message,
    welcome_message,
)

log = logging.getLogger("phice.server")

MAX_BAD_PACKETS = 20
MAX_FRAMES_PER_SEC = 200
TICK_HZ_ACTIVE = 50.0
TICK_HZ_IDLE = 5.0
ASSET_TYPES = {".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg",
               ".jpeg": "image/jpeg", ".css": "text/css; charset=utf-8",
               ".json": "application/json", ".woff2": "font/woff2", ".ico": "image/x-icon"}


def _resp(status: HTTPStatus, body: bytes, content_type: str, cache: str = "no-store") -> Response:
    headers = Headers({"Content-Type": content_type, "Content-Length": str(len(body)),
                       "Cache-Control": cache, "X-Content-Type-Options": "nosniff"})
    return Response(status.value, status.phrase, headers, body)


def _safe_asset(assets_dir: Path, rel: str) -> Path | None:
    if not rel or rel.startswith("/") or ".." in rel:
        return None
    target = (assets_dir / rel).resolve()
    try:
        target.relative_to(assets_dir.resolve())
    except ValueError:
        return None
    if not target.is_file() or target.suffix.lower() not in ASSET_TYPES:
        return None
    return target


@dataclass
class ServerState:
    paths: Paths
    pairing: PairingManager
    engine: PointerEngine
    layout: Layout
    config: PointerConfig
    accessibility: bool = True
    sensor_hz: float = 0.0
    caps: str = ""
    client: ServerConnection | None = None
    client_name: str = ""
    recorder: object | None = None  # an open text file while recording

    def record(self, raw: str) -> None:
        if self.recorder is None:
            return
        try:
            self.recorder.write(json.dumps({"rx": time.monotonic(), "raw": raw}) + "\n")
        except Exception:
            log.warning("recording stopped", exc_info=True)
            self.recorder = None


class PhiceServer:
    def __init__(self, state: ServerState, host: str, port: int, tls_host: str,
                 extra_origin_hosts: Callable[[], list[str]] | None = None):
        self.state = state
        self.host = host
        self.port = port
        self.tls_host = tls_host
        # The page may be reached by any name in the certificate's SANs -- an IP
        # address or a tailnet FQDN, not just <host>.local -- and the Origin it
        # sends back must be accepted. Evaluated per request because addresses
        # change with DHCP.
        self._extra_origin_hosts = extra_origin_hosts or (lambda: [])
        self._server = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._ticker: asyncio.Task | None = None

    # ----- HTTP -------------------------------------------------------------

    def _process_request(self, conn: ServerConnection, request) -> Response | None:
        path = request.path.split("?", 1)[0]
        if path == "/ws":
            origin = request.headers.get("Origin")
            hosts = [*san_names(self.tls_host), *self._extra_origin_hosts()]
            allowed = {f"https://{n}:{self.port}" for n in hosts}
            allowed |= {f"https://{n}" for n in hosts}
            if origin is not None and origin not in allowed:
                log.warning("rejecting websocket with origin %s", origin)
                return _resp(HTTPStatus.FORBIDDEN, b"bad origin", "text/plain")
            return None  # let the upgrade proceed
        if path in ("/", "/index.html"):
            return _resp(HTTPStatus.OK, (WEB_DIR / "index.html").read_bytes(),
                         "text/html; charset=utf-8")
        if path == "/app.js":
            return _resp(HTTPStatus.OK, (WEB_DIR / "app.js").read_bytes(),
                         "application/javascript; charset=utf-8")
        if path == "/theme.css":
            return _resp(HTTPStatus.OK, self.state.paths.theme_css.read_bytes(),
                         "text/css; charset=utf-8")
        if path == "/layout.json":
            return _resp(HTTPStatus.OK, self.state.paths.layout_json.read_bytes(), "application/json")
        if path.startswith("/assets/"):
            target = _safe_asset(self.state.paths.assets, path[len("/assets/"):])
            if target is None:
                return _resp(HTTPStatus.NOT_FOUND, b"not found", "text/plain")
            return _resp(HTTPStatus.OK, target.read_bytes(), ASSET_TYPES[target.suffix.lower()],
                         cache="max-age=60")
        return _resp(HTTPStatus.NOT_FOUND, b"not found", "text/plain")

    # ----- WebSocket --------------------------------------------------------

    async def _handler(self, conn: ServerConnection) -> None:
        st = self.state
        try:
            first = await asyncio.wait_for(conn.recv(), timeout=5.0)
        except (TimeoutError, Exception):
            return
        try:
            msg = parse_client_message(first if isinstance(first, str) else first.decode())
        except ProtocolError as e:
            await conn.send(err_message("bad_packet", str(e)))
            await conn.close(4002, "bad hello")
            return
        if not isinstance(msg, Hello):
            await conn.close(4002, "expected hello")
            return
        token = None
        if msg.token and st.pairing.check_device_token(msg.token):
            token = msg.token
        elif msg.pair:
            token = st.pairing.redeem_pairing_token(msg.pair, msg.name)
            if token:
                await conn.send(welcome_message(token))
        if not token:
            await conn.send(err_message("unpaired", "scan the pairing QR code on the Mac"))
            await conn.close(4003, "unpaired")
            return

        if st.client is not None and st.client is not conn:
            old = st.client
            st.client = None
            await old.close(4001, "replaced")
        st.client = conn
        st.client_name = msg.name
        st.caps = msg.caps
        # Session marker for tools/replay.py. Never record the raw hello: it carries a token.
        st.record(json.dumps({"t": "hello", "ver": msg.ver, "name": msg.name}))
        st.engine.connected()
        st.engine.on_change = lambda: self._schedule_state()
        await conn.send(layout_message(st.layout.to_dict()))
        await self._send_state()

        bad = 0
        window_start = asyncio.get_running_loop().time()
        frames = 0
        try:
            async for raw in conn:
                now = asyncio.get_running_loop().time()
                if now - window_start >= 1.0:
                    window_start, frames = now, 0
                frames += 1
                text = raw if isinstance(raw, str) else raw.decode("utf-8", "replace")
                st.record(text)
                if frames > MAX_FRAMES_PER_SEC:
                    await conn.close(4008, "too fast")
                    break
                try:
                    m = parse_client_message(text)
                except ProtocolError as e:
                    bad += 1
                    if bad >= MAX_BAD_PACKETS:
                        await conn.send(err_message("bad_packet", str(e)))
                        await conn.close(4002, "too many bad packets")
                        break
                    continue
                bad = 0
                if isinstance(m, SensorPacket):
                    if m.hz:
                        st.sensor_hz = m.hz
                    st.engine.handle(m)
                elif isinstance(m, Ping):
                    await conn.send(pong_message())
                elif isinstance(m, Bye):
                    break
        finally:
            if st.client is conn:
                st.client = None
                st.engine.on_change = None
                st.engine.disconnected()

    # ----- outbound ---------------------------------------------------------

    def _schedule_state(self) -> None:
        if self._loop:
            self._loop.create_task(self._send_state())

    async def _send_state(self) -> None:
        st = self.state
        conn = st.client
        if conn is None:
            return
        snap = st.engine.snapshot()
        cfg = st.engine.config
        msg = state_message(conn=True, power=snap.power, phase=snap.phase.value,
                            recenter=snap.recenter, idle_hz=cfg.idle_hz,
                            accessibility=st.accessibility,
                            ui={"haptics": cfg.ui.haptics, "keep_awake": cfg.ui.keep_awake,
                                "appearance": cfg.ui.appearance,
                                "recenter_ms": cfg.recenter_hold_ms})
        try:
            await conn.send(msg)
        except Exception:
            pass

    async def push_layout(self, layout: Layout) -> None:
        self.state.layout = layout
        self.state.engine.set_roles(layout.roles())
        if self.state.client:
            try:
                await self.state.client.send(layout_message(layout.to_dict()))
            except Exception:
                pass

    async def push_theme_changed(self) -> None:
        if self.state.client:
            try:
                await self.state.client.send(theme_changed_message())
            except Exception:
                pass

    # ----- lifecycle --------------------------------------------------------

    def ssl_context(self) -> ssl.SSLContext:
        cp = CertPaths.under(self.state.paths.certs)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cp.server_crt, cp.server_key)
        return ctx

    async def _tick_loop(self) -> None:
        """Drives time-based engine transitions: pending clicks, recenter, timeouts.

        Without this, a phone that stops sending (finger down, then Wi-Fi drops)
        would leave a button held forever.
        """
        last_recenter = -1.0
        while True:
            active = self.state.engine.phase.value in ("on", "hold", "held")
            await asyncio.sleep(1.0 / (TICK_HZ_ACTIVE if active else TICK_HZ_IDLE))
            try:
                self.state.engine.tick()
            except Exception:
                log.exception("engine tick failed")
            if self.state.engine.phase.value == "hold":
                prog = round(self.state.engine.recenter_progress(), 2)  # 1dp visibly steps
                if prog != last_recenter:
                    last_recenter = prog
                    await self._send_state()
            else:
                last_recenter = -1.0

    async def start(self) -> int:
        self._loop = asyncio.get_running_loop()
        self._ticker = asyncio.create_task(self._tick_loop())
        self._server = await serve(self._handler, self.host, self.port, ssl=self.ssl_context(),
                                   process_request=self._process_request, compression=None,
                                   ping_interval=20, ping_timeout=20, max_size=4096)
        self.port = self._server.sockets[0].getsockname()[1]
        return self.port

    async def stop(self) -> None:
        if self._ticker:
            self._ticker.cancel()
            self._ticker = None
        if self._server:
            self._server.close()
            await self._server.wait_closed()
