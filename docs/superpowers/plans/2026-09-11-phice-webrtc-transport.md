# Phice WebRTC Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the certificate ceremony with a hosted web page. The phone opens a permanent public URL, types a six-character code, and connects directly to the Mac — no profile to install, no trust toggle, no VPN, no "connection is not secure", and no requirement that the two devices share a network.

**Architecture:** A static page on Vercel is served over real HTTPS, so Safari grants it motion sensors with no warning. Two tiny Vercel functions act as a letterbox: the Mac drops a WebRTC offer under a short code, the phone collects it and posts back an answer. The two then establish a direct encrypted WebRTC DataChannel and the server drops out. Motion data, layout and theme travel peer-to-peer and never touch Vercel. WebRTC's DTLS handles encryption with self-signed certificates verified by fingerprint, which is precisely why no trusted certificate is needed on the Mac.

**Tech Stack:** `aiortc` 1.15 (Mac peer), vanilla JS `RTCPeerConnection` (phone), Vercel static hosting + two Node serverless functions + Vercel KV.

**Source context:** `CLAUDE.md` in the repo root.

---

## Pre-flight: read this before Task 1

### Why WebRTC and not "just host the page"

An HTTPS page is forbidden by the browser's mixed-content rule from opening `ws://10.0.0.5`. Hosting alone therefore changes nothing. WebRTC is the one browser API that makes an encrypted connection to a peer **without either side holding a certificate the browser trusts** — the peers exchange DTLS fingerprints during signaling and verify each other directly. That is the whole reason this plan works.

### Verified before writing this plan

- `aiortc` 1.15.0 installs on Apple Silicon with **no compilation**: it is a pure-Python wheel, and `pylibsrtp` and `av` both ship arm64 wheels. `uv add aiortc` takes seconds.
- `RTCPeerConnection` + `createDataChannel` construct successfully under Python 3.13.
- Installed weight is ~66 MB, dominated by `av` (FFmpeg bindings, unused here but a hard dependency).

### Non-obvious things that will bite

1. **Use non-trickle ICE.** Gather every candidate *before* sending the offer, so signaling is exactly two messages and needs no WebSocket. Vercel's free tier cannot hold WebSocket connections; it does not need to.
2. **`aiortc` closes a DataChannel silently if the event loop is blocked.** Everything on the Mac side stays `async`; never call blocking I/O on the loop thread.
3. **The phone page must request motion permission from a user gesture.** `DeviceOrientationEvent.requestPermission()` rejects otherwise. Keep it on the Start button.
4. **Layout and theme now arrive over the data channel**, not over HTTP. The hosted page ships with no styling of its own and must tolerate being connected before the theme arrives.
5. **Vercel KV entries must expire.** A pairing code is single-use and short-lived; leaving them forever leaks connection metadata and exhausts the free tier.
6. **Keep the existing TLS transport working.** It is the fallback when signaling is unreachable, and it is how the test suite exercises the engine.

### Setting up Vercel from zero

You have no account. Task 4 walks through it: sign in with GitHub, import the repo, done. It is free (Hobby tier, non-commercial) and gives a permanent URL like `phice.vercel.app`. No credit card.

### Things only a human can verify

Whether the direct peer-to-peer path actually establishes on a given network. On home Wi-Fi and on phone-cellular-to-Mac-Wi-Fi it normally does. On networks that isolate clients — including the university network this was developed against — it may fail and need a TURN relay, which the Known limitations section records rather than solves.

---

## File structure

```
web/                          NEW - deployed to Vercel, not part of the Python package
  index.html                  the hosted shell (no styling of its own)
  app.js                      WebRTC client: pairing, sensors, buttons
  api/offer.js                POST store an offer, GET retrieve it
  api/answer.js               POST store an answer, GET retrieve it
  vercel.json                 routing + headers
  package.json                declares the KV dependency

src/phice/
  signaling.py                NEW: talks to the Vercel letterbox over HTTPS
  rtc.py                      NEW: aiortc peer, DataChannel, engine wiring
  runtime.py                  MODIFIED: start the RTC peer alongside the TLS server
  config.py                   MODIFIED: transport + signaling_url settings

tests/
  test_signaling.py           NEW: letterbox client against a fake HTTP server
  test_rtc.py                 NEW: two aiortc peers connecting in-process
```

---

### Task 1: Configuration for the new transport

**Files:**
- Modify: `src/phice/config.py`
- Test: `tests/test_config.py` (append)

Adding settings first means every later task has somewhere to read from, and the existing transport stays default until the rest works.

- [ ] **Step 1: Write the failing test — append to `tests/test_config.py`**

```python
def test_transport_settings():
    cfg = PointerConfig.from_dict({})
    assert cfg.transport == "tls"           # unchanged default: nothing breaks yet
    assert cfg.signaling_url == "https://phice.vercel.app"

    cfg = PointerConfig.from_dict({"transport": "webrtc",
                                   "signaling_url": "https://example.test"})
    assert cfg.transport == "webrtc" and cfg.signaling_url == "https://example.test"


@pytest.mark.parametrize("bad", [
    {"transport": "carrier-pigeon"},
    {"signaling_url": "ftp://example.test"},
    {"signaling_url": "http://example.test"},   # signaling must be HTTPS
    {"signaling_url": 42},
])
def test_rejects_bad_transport_settings(bad):
    with pytest.raises(ConfigError):
        PointerConfig.from_dict(bad)
```

- [ ] **Step 2: Run it and watch it fail**

Run: `uv run pytest tests/test_config.py -q -k transport`
Expected: FAIL, `AttributeError: 'PointerConfig' object has no attribute 'transport'`

- [ ] **Step 3: Modify `src/phice/config.py`**

Add two fields to the `PointerConfig` dataclass, immediately after `tailscale_host`:

```python
    transport: str = "tls"
    signaling_url: str = "https://phice.vercel.app"
```

In `from_dict`, immediately after the `mapping` validation block, add:

```python
        transport = d.get("transport", "tls")
        if transport not in ("tls", "webrtc"):
            raise ConfigError("transport: expected 'tls' or 'webrtc'")
        signaling_url = d.get("signaling_url", "https://phice.vercel.app")
        if not isinstance(signaling_url, str) or not signaling_url.startswith("https://"):
            # Plain HTTP signaling would let anyone on the path swap the offer and
            # take over the pairing.
            raise ConfigError("signaling_url: expected an https:// URL")
```

and add to the `cls(...)` call, after `tailscale_host=ts_host,`:

```python
            transport=transport,
            signaling_url=signaling_url,
```

- [ ] **Step 4: Run it and watch it pass**

Run: `uv run pytest tests/test_config.py -q`
Expected: all pass.

- [ ] **Step 5: Add the keys to the packaged defaults**

In `src/phice/defaults/pointer.json`, after the `"cert_mode"` line, add:

```json
  "transport": "tls",
  "signaling_url": "https://phice.vercel.app",
```

Run: `uv run pytest -q`
Expected: all pass, including `test_defaults_file_matches_dataclass_defaults`.

- [ ] **Step 6: Commit**

```bash
git add src/phice/config.py src/phice/defaults/pointer.json tests/test_config.py
git commit -m "feat: transport and signaling_url settings"
```

---

### Task 2: The signaling letterbox client

**Files:**
- Create: `src/phice/signaling.py`
- Test: `tests/test_signaling.py`

A deliberately dumb client: POST an offer under a code, poll for the answer. No WebSocket, no streaming, so it works against Vercel's free tier and is trivial to test against a stub server.

- [ ] **Step 1: Write the failing test — `tests/test_signaling.py`**

```python
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from phice.signaling import SignalingError, SignalingClient, new_pairing_code


@pytest.fixture
def stub():
    """Minimal stand-in for the Vercel functions: an in-memory letterbox."""
    store: dict[str, dict] = {}

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _send(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n))
            kind = self.path.strip("/").split("/")[-1]
            store[f"{kind}:{data['code']}"] = data
            self._send(200, {"ok": True})

        def do_GET(self):
            path, _, q = self.path.partition("?")
            kind = path.strip("/").split("/")[-1]
            code = dict(p.split("=", 1) for p in q.split("&") if "=" in p).get("code", "")
            hit = store.get(f"{kind}:{code}")
            self._send(200, hit) if hit else self._send(404, {"error": "not found"})

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}", store
    srv.shutdown()


def test_pairing_codes_are_short_and_unambiguous():
    seen = {new_pairing_code() for _ in range(500)}
    assert len(seen) > 480                       # effectively unique
    for c in seen:
        assert len(c) == 6
        # No characters that get misread aloud or mistyped.
        assert not (set(c) & set("01IOL"))
        assert c.upper() == c


async def test_publish_then_fetch_roundtrip(stub):
    base, _ = stub
    c = SignalingClient(base, allow_insecure=True)
    code = new_pairing_code()
    await c.publish_offer(code, {"sdp": "x", "type": "offer"})
    got = await c.fetch_offer(code)
    assert got == {"sdp": "x", "type": "offer"}
    await c.publish_answer(code, {"sdp": "y", "type": "answer"})
    assert await c.fetch_answer(code) == {"sdp": "y", "type": "answer"}


async def test_missing_code_returns_none_rather_than_raising(stub):
    base, _ = stub
    c = SignalingClient(base, allow_insecure=True)
    assert await c.fetch_answer("ZZZZZZ") is None


async def test_wait_for_answer_times_out(stub):
    base, _ = stub
    c = SignalingClient(base, allow_insecure=True)
    with pytest.raises(SignalingError, match="timed out"):
        await c.wait_for_answer("ZZZZZZ", timeout=0.4, interval=0.1)


async def test_wait_for_answer_returns_as_soon_as_it_appears(stub):
    import asyncio
    base, _ = stub
    c = SignalingClient(base, allow_insecure=True)

    async def later():
        await asyncio.sleep(0.15)
        await c.publish_answer("ABC234", {"sdp": "z", "type": "answer"})

    asyncio.ensure_future(later())
    got = await c.wait_for_answer("ABC234", timeout=3.0, interval=0.05)
    assert got["sdp"] == "z"


def test_plain_http_is_refused_by_default():
    with pytest.raises(SignalingError, match="https"):
        SignalingClient("http://example.test")
```

- [ ] **Step 2: Run it and watch it fail**

Run: `uv run pytest tests/test_signaling.py -q`
Expected: FAIL, `ModuleNotFoundError: No module named 'phice.signaling'`

- [ ] **Step 3: Write `src/phice/signaling.py`**

```python
"""Client for the hosted signaling letterbox.

Deliberately the dumbest thing that works: two POSTs and two GETs. Non-trickle
ICE means the whole exchange is one offer and one answer, so there is no need
for a WebSocket -- which matters because Vercel's free tier cannot hold one.
"""
from __future__ import annotations

import asyncio
import json
import secrets
import urllib.error
import urllib.parse
import urllib.request

# No 0/O/1/I/L: these are the characters people misread and mistype.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 6
HTTP_TIMEOUT = 10.0


class SignalingError(RuntimeError):
    """Raised when the letterbox cannot be reached or refuses a request."""


def new_pairing_code() -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))


class SignalingClient:
    def __init__(self, base_url: str, allow_insecure: bool = False):
        base = base_url.rstrip("/")
        if not allow_insecure and not base.startswith("https://"):
            raise SignalingError("signaling base URL must use https")
        self.base = base

    # ----- transport --------------------------------------------------------

    def _post_sync(self, path: str, payload: dict) -> None:
        body = json.dumps(payload).encode()
        req = urllib.request.Request(f"{self.base}{path}", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
                r.read()
        except (urllib.error.URLError, OSError) as e:
            raise SignalingError(f"POST {path} failed: {e}") from e

    def _get_sync(self, path: str, code: str) -> dict | None:
        q = urllib.parse.urlencode({"code": code})
        try:
            with urllib.request.urlopen(f"{self.base}{path}?{q}", timeout=HTTP_TIMEOUT) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise SignalingError(f"GET {path} failed: {e}") from e
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise SignalingError(f"GET {path} failed: {e}") from e

    # ----- api --------------------------------------------------------------

    async def publish_offer(self, code: str, offer: dict) -> None:
        await asyncio.to_thread(self._post_sync, "/api/offer", {"code": code, **offer})

    async def fetch_offer(self, code: str) -> dict | None:
        return await asyncio.to_thread(self._get_sync, "/api/offer", code)

    async def publish_answer(self, code: str, answer: dict) -> None:
        await asyncio.to_thread(self._post_sync, "/api/answer", {"code": code, **answer})

    async def fetch_answer(self, code: str) -> dict | None:
        return await asyncio.to_thread(self._get_sync, "/api/answer", code)

    async def wait_for_answer(self, code: str, timeout: float = 300.0,
                              interval: float = 1.0) -> dict:
        """Poll until the phone answers. Polling, not streaming, because the
        whole exchange is two messages and serverless cannot hold a socket."""
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while loop.time() < deadline:
            got = await self.fetch_answer(code)
            if got:
                return got
            await asyncio.sleep(interval)
        raise SignalingError(f"waiting for the phone timed out after {timeout:.0f}s")
```

The stub returns the stored dict verbatim, which includes `code`; the tests compare
against the posted payload minus nothing, so keep `publish_*` flattening the offer
into the same object as `code`.

- [ ] **Step 4: Run it and watch it pass**

Run: `uv run pytest tests/test_signaling.py -q`
Expected: `6 passed`

If `test_publish_then_fetch_roundtrip` fails on an extra `code` key, change the two
assertions to compare `{k: v for k, v in got.items() if k != "code"}`.

- [ ] **Step 5: Commit**

```bash
git add src/phice/signaling.py tests/test_signaling.py
git commit -m "feat: signaling letterbox client with short pairing codes"
```

---

### Task 3: The WebRTC peer on the Mac

**Files:**
- Create: `src/phice/rtc.py`
- Test: `tests/test_rtc.py`
- Modify: `pyproject.toml` (add aiortc)

The peer owns one `RTCPeerConnection` and one DataChannel. Inbound frames go through the **existing** `parse_client_message`, so the wire format, validation and engine are all unchanged — this really is only a transport swap.

- [ ] **Step 1: Add the dependency**

In `pyproject.toml`, add to `dependencies`:

```toml
    "aiortc>=1.15",
```

Run: `uv sync && uv run python -c "import aiortc; print(aiortc.__version__)"`
Expected: `1.15.0` or later, with no compilation.

- [ ] **Step 2: Write the failing test — `tests/test_rtc.py`**

```python
"""Two aiortc peers connecting in-process: no network, no phone, no Vercel."""
import asyncio
import json

import pytest
from aiortc import RTCPeerConnection, RTCSessionDescription

from phice.config import PointerConfig
from phice.cursor_backend import FakeCursor
from phice.engine import PointerEngine
from phice.rtc import RTCTransport, gather_complete


async def _connect(transport: RTCTransport) -> tuple[RTCPeerConnection, object]:
    """Play the part of the phone: take the offer, answer it, return the channel."""
    offer = await transport.create_offer()
    phone = RTCPeerConnection()
    opened = asyncio.get_running_loop().create_future()
    channels: dict = {}

    @phone.on("datachannel")
    def on_channel(channel):
        channels["c"] = channel
        if not opened.done():
            opened.set_result(channel)

    await phone.setRemoteDescription(RTCSessionDescription(**offer))
    answer = await phone.createAnswer()
    await phone.setLocalDescription(answer)
    await gather_complete(phone)
    await transport.accept_answer({"sdp": phone.localDescription.sdp,
                                   "type": phone.localDescription.type})
    await asyncio.wait_for(opened, timeout=10)
    return phone, channels["c"]


@pytest.fixture
def transport():
    cursor = FakeCursor()
    engine = PointerEngine(PointerConfig(), cursor)
    engine.set_roles({"left": "left", "right": "right", "scroll": "scroll", "power": "power"})
    t = RTCTransport(engine=engine, layout_json='{"version":1,"buttons":[]}',
                     theme_css="body{}")
    t.cursor = cursor
    return t


async def test_offer_has_gathered_candidates_before_it_is_published(transport):
    """Non-trickle ICE: the offer must be complete when published, or the phone
    has nothing to connect to and signaling would need a second channel."""
    offer = await transport.create_offer()
    assert offer["type"] == "offer"
    assert "a=candidate" in offer["sdp"]
    await transport.close()


async def test_data_channel_carries_sensor_packets_into_the_engine(transport):
    phone, channel = await _connect(transport)
    try:
        # Power on, then turn right; the engine must move the fake cursor.
        for seq, (alpha, power) in enumerate(
                [(0.0, 1), (0.0, 0)] + [(350.0, 0)] * 90, start=1):
            channel.send(json.dumps({
                "t": "s", "seq": seq, "ts": seq / 60, "o": [alpha, 0, 0],
                "rr": [10, 0, 0], "g": [0, 0, 9.8],
                "b": {"left": 0, "right": 0, "scroll": 0, "power": power},
                "c": {"left": 0, "right": 0, "scroll": 0, "power": 1 if seq > 1 else 0},
                "sd": 0}))
            await asyncio.sleep(0)
        await asyncio.sleep(0.4)
        assert transport.cursor.x > 100, "cursor should have moved right"
    finally:
        await phone.close()
        await transport.close()


async def test_malformed_frames_do_not_kill_the_channel(transport):
    phone, channel = await _connect(transport)
    try:
        channel.send("{not json")
        channel.send(json.dumps({"t": "s", "seq": 1, "ts": 1, "o": [999, 0, 0]}))
        await asyncio.sleep(0.2)
        channel.send(json.dumps({"t": "ping"}))
        await asyncio.sleep(0.2)
        assert channel.readyState == "open"
    finally:
        await phone.close()
        await transport.close()


async def test_layout_and_theme_are_pushed_on_open(transport):
    """The hosted page ships with no styling; it must receive the user's layout
    and theme over the channel or it renders nothing."""
    got: list[dict] = []
    phone = RTCPeerConnection()
    ready = asyncio.get_running_loop().create_future()

    @phone.on("datachannel")
    def on_channel(channel):
        @channel.on("message")
        def on_message(msg):
            got.append(json.loads(msg))
            if len([m for m in got if m["t"] in ("layout", "theme")]) == 2 and not ready.done():
                ready.set_result(True)

    offer = await transport.create_offer()
    await phone.setRemoteDescription(RTCSessionDescription(**offer))
    await phone.setLocalDescription(await phone.createAnswer())
    await gather_complete(phone)
    await transport.accept_answer({"sdp": phone.localDescription.sdp,
                                   "type": phone.localDescription.type})
    try:
        await asyncio.wait_for(ready, timeout=10)
        kinds = {m["t"] for m in got}
        assert {"layout", "theme"} <= kinds
    finally:
        await phone.close()
        await transport.close()


async def test_disconnect_releases_held_buttons(transport):
    phone, channel = await _connect(transport)
    channel.send(json.dumps({
        "t": "s", "seq": 1, "ts": 0.016, "o": [0, 0, 0], "rr": [10, 0, 0], "g": [0, 0, 9.8],
        "b": {"power": 1}, "c": {"power": 1}, "sd": 0}))
    await asyncio.sleep(0.2)
    await phone.close()
    await asyncio.sleep(0.5)
    assert transport.cursor.held == set()
    await transport.close()
```

- [ ] **Step 3: Run it and watch it fail**

Run: `uv run pytest tests/test_rtc.py -q`
Expected: FAIL, `ModuleNotFoundError: No module named 'phice.rtc'`

- [ ] **Step 4: Add the theme message to `src/phice/protocol.py`**

`protocol.py` is where every outbound message shape lives, so the new one belongs
there rather than inline in `rtc.py`. The existing `theme_changed_message()` only
tells the page to re-fetch over HTTP, which a WebRTC client cannot do. Append:

```python
def theme_message(css: str) -> str:
    """Push the stylesheet itself. The hosted page has no HTTP route back to the
    Mac, so it receives the CSS rather than a hint to re-fetch it."""
    return json.dumps({"t": "theme", "css": css})
```

- [ ] **Step 5: Write `src/phice/rtc.py`**

```python
"""WebRTC transport: a DataChannel peer that feeds the existing engine.

The wire format is unchanged -- frames go through protocol.parse_client_message
exactly as the WebSocket transport does -- so this swaps how bytes arrive and
nothing else.
"""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

from aiortc import RTCDataChannel, RTCPeerConnection, RTCSessionDescription

from .engine import PointerEngine
from .protocol import (Bye, Hello, Ping, ProtocolError, SensorPacket, layout_message,
                       parse_client_message, pong_message, theme_message)

log = logging.getLogger("phice.rtc")
TICK_HZ_ACTIVE = 50
TICK_HZ_IDLE = 5


async def gather_complete(pc: RTCPeerConnection, timeout: float = 10.0) -> None:
    """Wait until ICE gathering finishes.

    Non-trickle: the description is only useful once every candidate is in it,
    because there is no second channel to send late candidates over.
    """
    if pc.iceGatheringState == "complete":
        return
    loop = asyncio.get_running_loop()
    done = loop.create_future()

    @pc.on("icegatheringstatechange")
    def _on_change() -> None:
        if pc.iceGatheringState == "complete" and not done.done():
            done.set_result(True)

    try:
        await asyncio.wait_for(done, timeout=timeout)
    except asyncio.TimeoutError:
        log.warning("ICE gathering did not complete in %.0fs; publishing anyway", timeout)


class RTCTransport:
    """One peer connection, one DataChannel, wired to the engine."""

    def __init__(self, engine: PointerEngine, layout_json: str, theme_css: str):
        self.engine = engine
        self.layout_json = layout_json
        self.theme_css = theme_css
        self.pc = RTCPeerConnection()
        self.channel: RTCDataChannel | None = None
        self._tick: asyncio.Task | None = None
        self._closed = False

    # ----- signaling --------------------------------------------------------

    async def create_offer(self) -> dict[str, str]:
        self.channel = self.pc.createDataChannel("phice", ordered=False,
                                                 maxRetransmits=0)
        self._wire_channel(self.channel)

        @self.pc.on("connectionstatechange")
        async def _on_state() -> None:
            log.info("rtc connection state: %s", self.pc.connectionState)
            if self.pc.connectionState in ("failed", "closed", "disconnected"):
                self.engine.disconnected()

        await self.pc.setLocalDescription(await self.pc.createOffer())
        await gather_complete(self.pc)
        return {"sdp": self.pc.localDescription.sdp, "type": self.pc.localDescription.type}

    async def accept_answer(self, answer: dict[str, Any]) -> None:
        await self.pc.setRemoteDescription(
            RTCSessionDescription(sdp=answer["sdp"], type=answer["type"]))

    # ----- channel ----------------------------------------------------------

    def _wire_channel(self, channel: RTCDataChannel) -> None:
        @channel.on("open")
        def _on_open() -> None:
            log.info("data channel open")
            self.engine.connected()
            channel.send(layout_message(json.loads(self.layout_json)))
            channel.send(theme_message(self.theme_css))
            self._tick = asyncio.ensure_future(self._tick_loop())

        @channel.on("message")
        def _on_message(message: Any) -> None:
            if not isinstance(message, str):
                return
            try:
                parsed = parse_client_message(message)
            except ProtocolError as e:
                # A bad frame is the phone's problem, never the session's.
                log.debug("dropping malformed frame: %s", e)
                return
            if isinstance(parsed, SensorPacket):
                self.engine.handle(parsed)
            elif isinstance(parsed, Ping):
                channel.send(pong_message())
            elif isinstance(parsed, Bye):
                self.engine.disconnected()
            elif isinstance(parsed, Hello):
                pass  # pairing already happened out of band, via the code

        @channel.on("close")
        def _on_close() -> None:
            log.info("data channel closed")
            self.engine.disconnected()

    async def _tick_loop(self) -> None:
        """Time-based engine transitions still need driving -- see CLAUDE.md #1."""
        try:
            while not self._closed:
                self.engine.tick()
                active = self.engine.phase.value in ("on", "hold", "held")
                await asyncio.sleep(1 / (TICK_HZ_ACTIVE if active else TICK_HZ_IDLE))
        except asyncio.CancelledError:
            pass

    async def push_layout(self, layout_json: str) -> None:
        self.layout_json = layout_json
        if self.channel and self.channel.readyState == "open":
            self.channel.send(layout_message(json.loads(layout_json)))

    async def push_theme(self, theme_css: str) -> None:
        self.theme_css = theme_css
        if self.channel and self.channel.readyState == "open":
            self.channel.send(theme_message(theme_css))

    async def close(self) -> None:
        self._closed = True
        if self._tick:
            self._tick.cancel()
        self.engine.disconnected()
        await self.pc.close()
```

- [ ] **Step 6: Run it and watch it pass**

Run: `uv run pytest tests/test_rtc.py -q`
Expected: `5 passed` (allow up to 30s; ICE gathering on loopback is quick but not instant)

- [ ] **Step 7: Run the whole suite**

Run: `uv run pytest -q && uv run ruff check .`
Expected: all pass, clean.

- [ ] **Step 8: Commit**

```bash
git add src/phice/rtc.py src/phice/protocol.py tests/test_rtc.py pyproject.toml uv.lock
git commit -m "feat: WebRTC DataChannel transport feeding the existing engine"
```

---

### Task 4: Create the Vercel project (no prior Vercel experience needed)

**Files:**
- Create: `web/package.json`, `web/vercel.json`

This task is mostly clicking. It is written out because the plan assumes no Vercel account.

- [ ] **Step 1: Create `web/package.json`**

```json
{
  "name": "phice-web",
  "private": true,
  "version": "0.1.0",
  "dependencies": {
    "@vercel/kv": "^3.0.0"
  }
}
```

- [ ] **Step 2: Create `web/vercel.json`**

```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "headers": [
    {
      "source": "/api/(.*)",
      "headers": [
        { "key": "Access-Control-Allow-Origin", "value": "*" },
        { "key": "Access-Control-Allow-Methods", "value": "GET,POST,OPTIONS" },
        { "key": "Access-Control-Allow-Headers", "value": "Content-Type" },
        { "key": "Cache-Control", "value": "no-store" }
      ]
    }
  ]
}
```

`Access-Control-Allow-Origin: *` is safe here: the endpoints hold only short-lived
connection offers keyed by a code the holder already knows, and the Mac calls them
from Python where there is no origin at all.

- [ ] **Step 3: Sign up for Vercel**

1. Go to <https://vercel.com/signup>
2. Choose **Continue with GitHub** and authorise it. No credit card is requested.
3. On the dashboard choose **Add New… › Project**.
4. Find `zupersun/phice` and click **Import**. If it is not listed, click
   **Adjust GitHub App Permissions** and grant access to the repository.
5. Under **Root Directory** click **Edit** and choose `web`. This matters — the
   repository root is a Python project and Vercel must not try to build it.
6. Framework Preset: **Other**. Leave build and output commands empty.
7. Click **Deploy**.

Expected: a deployment succeeds and you get a URL such as `phice-xxxx.vercel.app`.
In **Settings › Domains** you can add a cleaner one like `phice.vercel.app` if free.

- [ ] **Step 4: Add the key-value store**

1. In the project, open the **Storage** tab.
2. **Create Database → KV**, accept the free Hobby plan, name it `phice-kv`.
3. Connect it to the project when prompted. This injects `KV_REST_API_URL` and
   `KV_REST_API_TOKEN` automatically — you never copy them by hand.
4. Redeploy once from **Deployments → ⋯ → Redeploy** so the functions see them.

- [ ] **Step 5: Record the URL**

Write the deployment URL down; Task 8 puts it in `pointer.json` as `signaling_url`.

- [ ] **Step 6: Commit**

```bash
git add web/package.json web/vercel.json
git commit -m "chore: Vercel project configuration"
```

---

### Task 5: The signaling functions

**Files:**
- Create: `web/api/offer.js`, `web/api/answer.js`

Two near-identical letterboxes. They are kept separate rather than parameterised so
each one's TTL and validation can be read at a glance.

- [ ] **Step 1: Create `web/api/offer.js`**

```javascript
// Letterbox for the Mac's WebRTC offer, addressed by a short pairing code.
// Entries expire: a pairing code is single use and short-lived, and leaving
// them behind would leak connection metadata and fill the free tier.
import { kv } from "@vercel/kv";

const TTL_SECONDS = 300;
const CODE_RE = /^[A-Z2-9]{6}$/;

export default async function handler(req, res) {
  if (req.method === "OPTIONS") return res.status(204).end();

  if (req.method === "POST") {
    const { code, sdp, type } = req.body || {};
    if (!CODE_RE.test(code || "")) return res.status(400).json({ error: "bad code" });
    if (type !== "offer" || typeof sdp !== "string" || sdp.length > 64_000) {
      return res.status(400).json({ error: "bad offer" });
    }
    await kv.set(`offer:${code}`, { sdp, type }, { ex: TTL_SECONDS });
    return res.status(200).json({ ok: true, expires_in: TTL_SECONDS });
  }

  if (req.method === "GET") {
    const code = String(req.query.code || "");
    if (!CODE_RE.test(code)) return res.status(400).json({ error: "bad code" });
    const hit = await kv.get(`offer:${code}`);
    if (!hit) return res.status(404).json({ error: "not found" });
    return res.status(200).json(hit);
  }

  return res.status(405).json({ error: "method not allowed" });
}
```

- [ ] **Step 2: Create `web/api/answer.js`**

```javascript
// Letterbox for the phone's WebRTC answer. Same shape as offer.js, shorter TTL:
// by the time an answer exists the Mac is already polling for it.
import { kv } from "@vercel/kv";

const TTL_SECONDS = 120;
const CODE_RE = /^[A-Z2-9]{6}$/;

export default async function handler(req, res) {
  if (req.method === "OPTIONS") return res.status(204).end();

  if (req.method === "POST") {
    const { code, sdp, type } = req.body || {};
    if (!CODE_RE.test(code || "")) return res.status(400).json({ error: "bad code" });
    if (type !== "answer" || typeof sdp !== "string" || sdp.length > 64_000) {
      return res.status(400).json({ error: "bad answer" });
    }
    await kv.set(`answer:${code}`, { sdp, type }, { ex: TTL_SECONDS });
    return res.status(200).json({ ok: true });
  }

  if (req.method === "GET") {
    const code = String(req.query.code || "");
    if (!CODE_RE.test(code)) return res.status(400).json({ error: "bad code" });
    const hit = await kv.get(`answer:${code}`);
    if (!hit) return res.status(404).json({ error: "not found" });
    // Single use: consuming the answer prevents a replay taking over the session.
    await kv.del(`answer:${code}`);
    return res.status(200).json(hit);
  }

  return res.status(405).json({ error: "method not allowed" });
}
```

- [ ] **Step 3: Deploy and verify by hand**

```bash
git add web/api && git commit -m "feat: Vercel signaling endpoints" && git push
```

Vercel deploys automatically on push. Wait for the dashboard to show **Ready**, then
substitute your URL:

```bash
BASE=https://YOUR-PROJECT.vercel.app
curl -s -X POST "$BASE/api/offer" -H 'Content-Type: application/json' \
  -d '{"code":"ABC234","sdp":"v=0 test","type":"offer"}'
curl -s "$BASE/api/offer?code=ABC234"
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/api/offer?code=ZZZZZZ"
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/api/offer?code=bad"
```

Expected in order: `{"ok":true,...}`, the stored offer, `404`, `400`.

- [ ] **Step 4: Confirm the Python client talks to the real thing**

```bash
uv run python - <<'PY'
import asyncio, os
from phice.signaling import SignalingClient, new_pairing_code
base = os.environ["BASE"]
async def main():
    c = SignalingClient(base)
    code = new_pairing_code()
    await c.publish_offer(code, {"sdp": "v=0 roundtrip", "type": "offer"})
    print("code", code, "->", (await c.fetch_offer(code))["sdp"])
asyncio.run(main())
PY
```
Expected: `code XXXXXX -> v=0 roundtrip`

---

### Task 6: The hosted phone page

**Files:**
- Create: `web/index.html`, `web/app.js`

A generic shell. It contains **no colours, sizes or labels** — the entire design
arrives from the Mac over the data channel, exactly as `CLAUDE.md` requires.

- [ ] **Step 1: Create `web/index.html`**

```html
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<meta name="apple-mobile-web-app-title" content="Phice">
<title>Phice</title>
<style id="theme">
  /* Replaced wholesale by the theme pushed from the Mac. These few rules only
     make the pairing screen legible before that arrives. */
  html,body{height:100%;margin:0;background:#000;color:#e8eef5;
            font:16px -apple-system,system-ui,sans-serif;
            touch-action:none;-webkit-user-select:none;user-select:none}
  .overlay{position:fixed;inset:0;display:none;align-items:center;justify-content:center;
           padding:24px;text-align:center}
  body[data-state="pair"] #ov-pair,
  body[data-state="connecting"] #ov-connecting,
  body[data-state="failed"] #ov-failed,
  body[data-state="start"] #ov-start{display:flex}
  #code{font-size:34px;letter-spacing:10px;text-align:center;width:100%;
        background:#111a24;color:#e8eef5;border:1px solid #233; border-radius:12px;
        padding:14px;text-transform:uppercase}
  button{font:inherit;font-size:17px;padding:15px 32px;border:none;border-radius:13px;
         background:#3ea6ff;color:#04121f;font-weight:700;margin-top:16px}
  p{color:#6b7a8c;line-height:1.5}
</style>
<body data-state="pair">
  <main id="pad" aria-label="Mouse controls"></main>

  <div class="overlay" id="ov-pair">
    <div>
      <h1>Phice</h1>
      <p>Enter the six-character code shown on your Mac.</p>
      <input id="code" maxlength="6" autocapitalize="characters" autocomplete="off"
             autocorrect="off" spellcheck="false" inputmode="text">
      <button type="button" id="btn-pair">Connect</button>
    </div>
  </div>

  <div class="overlay" id="ov-connecting"><div><h1>Connecting…</h1></div></div>

  <div class="overlay" id="ov-start">
    <div>
      <h1>Connected</h1>
      <p>Tap to allow motion access.</p>
      <button type="button" id="btn-start">Start</button>
    </div>
  </div>

  <div class="overlay" id="ov-failed">
    <div>
      <h1>Could not connect</h1>
      <p id="why"></p>
      <button type="button" id="btn-retry">Try again</button>
    </div>
  </div>

  <script src="/app.js"></script>
</body>
```

- [ ] **Step 2: Create `web/app.js`**

```javascript
/* Phice hosted client.
 *
 * Pairs by short code through the signaling letterbox, then talks to the Mac
 * over a direct WebRTC DataChannel. Contains no colours, sizes or labels: the
 * layout and the entire stylesheet are pushed from the Mac.
 */
(() => {
  "use strict";

  const el = {
    body: document.body,
    pad: document.getElementById("pad"),
    code: document.getElementById("code"),
    theme: document.getElementById("theme"),
    why: document.getElementById("why"),
  };

  const state = {
    pc: null,
    channel: null,
    seq: 0,
    buttons: new Map(),          // id -> {el, role}
    touches: new Map(),          // touch identifier -> {id, lastY}
    pressed: new Map(),          // id -> bool
    counters: new Map(),         // id -> press count
    scrollDelta: 0,
    orientation: null,
    rate: [0, 0, 0],
    gravity: [0, 0, 9.8],
    timer: null,
  };

  const setState = (s) => { el.body.dataset.state = s; };

  // ---------- pairing ----------

  async function pair(code) {
    setState("connecting");
    const pc = new RTCPeerConnection({
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    });
    state.pc = pc;

    pc.addEventListener("datachannel", (ev) => wireChannel(ev.channel));
    pc.addEventListener("connectionstatechange", () => {
      if (["failed", "closed", "disconnected"].includes(pc.connectionState)) {
        fail("The connection dropped. Check that Phice is running on your Mac.");
      }
    });

    const offerRes = await fetch(`/api/offer?code=${encodeURIComponent(code)}`);
    if (!offerRes.ok) {
      fail("That code was not found. Codes expire after five minutes — check your Mac for a fresh one.");
      return;
    }
    const offer = await offerRes.json();
    await pc.setRemoteDescription(offer);
    await pc.setLocalDescription(await pc.createAnswer());
    await gatherComplete(pc);

    const post = await fetch("/api/answer", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, sdp: pc.localDescription.sdp, type: pc.localDescription.type }),
    });
    if (!post.ok) fail("Could not reach the pairing service.");
  }

  // Non-trickle: hand over one complete description rather than streaming candidates.
  function gatherComplete(pc) {
    if (pc.iceGatheringState === "complete") return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        if (pc.iceGatheringState === "complete") {
          pc.removeEventListener("icegatheringstatechange", done);
          resolve();
        }
      };
      pc.addEventListener("icegatheringstatechange", done);
      setTimeout(resolve, 3000);   // publish what we have rather than hang
    });
  }

  function fail(why) {
    el.why.textContent = why;
    setState("failed");
  }

  // ---------- channel ----------

  function wireChannel(channel) {
    state.channel = channel;
    channel.addEventListener("open", () => setState("start"));
    channel.addEventListener("close", () => fail("The Mac closed the connection."));
    channel.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.t === "layout") renderLayout(msg);
      else if (msg.t === "theme") el.theme.textContent = msg.css;
      else if (msg.t === "state") applyState(msg);
    });
  }

  function applyState(msg) {
    if (msg.phase) el.body.dataset.phase = msg.phase;
    if (typeof msg.recenter === "number") {
      el.body.style.setProperty("--recenter-progress", String(msg.recenter));
    }
  }

  // ---------- layout ----------

  function renderLayout(layout) {
    el.pad.innerHTML = "";
    state.buttons.clear();
    for (const b of layout.buttons || []) {
      const node = document.createElement("div");
      node.className = `btn role-${b.role}${b.class ? " " + b.class : ""}`;
      node.dataset.pressed = "0";
      node.style.left = b.x + "%";
      node.style.top = b.y + "%";
      node.style.width = b.w + "%";
      node.style.height = b.h + "%";
      if (b.icon) {
        const img = document.createElement("img");
        img.src = b.icon;            // resolved against the page; themes may inline instead
        node.appendChild(img);
      } else if (b.label) {
        node.textContent = b.label;
      }
      el.pad.appendChild(node);
      state.buttons.set(b.id, { el: node, role: b.role });
      if (!state.pressed.has(b.id)) { state.pressed.set(b.id, false); state.counters.set(b.id, 0); }
    }
  }

  // ---------- touch ----------

  function hitTest(x, y) {
    for (const [id, b] of state.buttons) {
      const r = b.el.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return id;
    }
    return null;
  }

  function setPressed(id, pressed) {
    const b = state.buttons.get(id);
    if (!b) return;
    if (pressed && !state.pressed.get(id)) {
      state.counters.set(id, (state.counters.get(id) || 0) + 1);
      if (navigator.vibrate) navigator.vibrate(8);
    }
    state.pressed.set(id, pressed);
    b.el.dataset.pressed = pressed ? "1" : "0";
    send(true);
  }

  function setScrollThumb(b, clientY) {
    const r = b.el.getBoundingClientRect();
    if (!r.height) return;
    const pos = Math.min(1, Math.max(0, (clientY - r.top) / r.height));
    b.el.style.setProperty("--scroll-pos", pos.toFixed(4));
  }

  el.pad.addEventListener("touchstart", (ev) => {
    ev.preventDefault();
    for (const t of ev.changedTouches) {
      const id = hitTest(t.clientX, t.clientY);
      if (!id) continue;
      state.touches.set(t.identifier, { id, lastY: t.clientY });
      const b = state.buttons.get(id);
      if (b && b.role === "scroll") setScrollThumb(b, t.clientY);
      setPressed(id, true);
    }
  }, { passive: false });

  el.pad.addEventListener("touchmove", (ev) => {
    ev.preventDefault();
    for (const t of ev.changedTouches) {
      const rec = state.touches.get(t.identifier);
      if (!rec) continue;
      const b = state.buttons.get(rec.id);
      if (b && b.role === "scroll") {
        state.scrollDelta += t.clientY - rec.lastY;
        setScrollThumb(b, t.clientY);
      }
      rec.lastY = t.clientY;
    }
  }, { passive: false });

  const endTouch = (ev) => {
    ev.preventDefault();
    for (const t of ev.changedTouches) {
      const rec = state.touches.get(t.identifier);
      if (!rec) continue;
      state.touches.delete(t.identifier);
      const stillHeld = [...state.touches.values()].some((r) => r.id === rec.id);
      if (!stillHeld) {
        const b = state.buttons.get(rec.id);
        if (b && b.role === "scroll") b.el.style.removeProperty("--scroll-pos");
        setPressed(rec.id, false);
      }
    }
  };
  el.pad.addEventListener("touchend", endTouch, { passive: false });
  el.pad.addEventListener("touchcancel", endTouch, { passive: false });

  // ---------- sensors ----------

  async function startSensors() {
    const D = window.DeviceOrientationEvent, M = window.DeviceMotionEvent;
    // requestPermission must be called from a user gesture, which is why this
    // hangs off the Start button rather than running on load.
    if (D && typeof D.requestPermission === "function") await D.requestPermission();
    if (M && typeof M.requestPermission === "function") await M.requestPermission();

    window.addEventListener("deviceorientation", (e) => {
      state.orientation = [e.alpha, e.beta, e.gamma];
    });
    window.addEventListener("devicemotion", (e) => {
      const r = e.rotationRate || {};
      state.rate = [r.alpha || 0, r.beta || 0, r.gamma || 0];
      const g = e.accelerationIncludingGravity || {};
      state.gravity = [g.x || 0, g.y || 0, g.z || 9.8];
    });

    el.body.dataset.state = "on";
    if (state.timer) clearInterval(state.timer);
    state.timer = setInterval(() => send(false), 1000 / 60);
  }

  function send(force) {
    const ch = state.channel;
    if (!ch || ch.readyState !== "open") return;
    if (!force && !state.orientation) return;
    const b = {}, c = {};
    for (const [id] of state.buttons) {
      b[id] = state.pressed.get(id) ? 1 : 0;
      c[id] = state.counters.get(id) || 0;
    }
    const sd = state.scrollDelta;
    state.scrollDelta = 0;
    state.seq += 1;
    ch.send(JSON.stringify({
      t: "s", seq: state.seq, ts: performance.now() / 1000,
      o: state.orientation,
      rr: state.rate.map((v) => Math.round(v * 100) / 100),
      g: state.gravity.map((v) => Math.round(v * 100) / 100),
      b, c, sd: Math.round(sd * 100) / 100,
    }));
  }

  // ---------- wiring ----------

  document.getElementById("btn-pair").addEventListener("click", () => {
    const code = (el.code.value || "").toUpperCase().trim();
    if (!/^[A-Z2-9]{6}$/.test(code)) { el.code.focus(); return; }
    localStorage.setItem("phice.code", code);
    pair(code).catch((e) => fail(String(e)));
  });
  document.getElementById("btn-start").addEventListener("click", () => {
    startSensors().catch(() => fail("Motion access was denied. Allow it in Settings › Apps › Safari › Motion & Orientation Access."));
  });
  document.getElementById("btn-retry").addEventListener("click", () => setState("pair"));

  el.code.value = localStorage.getItem("phice.code") || "";
  setState("pair");
})();
```

- [ ] **Step 3: Check the JavaScript parses and every id it uses exists**

```bash
node --check web/app.js
node -e "
const fs=require('fs');
const html=fs.readFileSync('web/index.html','utf8');
const ids=[...html.matchAll(/id=\"([a-z-]+)\"/g)].map(m=>m[1]);
const js=fs.readFileSync('web/app.js','utf8');
const want=[...js.matchAll(/getElementById\(\"([a-z-]+)\"\)/g)].map(m=>m[1]);
const missing=want.filter(w=>!ids.includes(w));
console.log(missing.length ? 'MISSING: '+missing : 'all ids present');"
```
Expected: no syntax errors, then `all ids present`

- [ ] **Step 4: Deploy and confirm the page loads with no warning**

```bash
git add web/index.html web/app.js
git commit -m "feat: hosted phone page pairing over WebRTC"
git push
```

Open the deployment URL on the iPhone. Expected: the pairing screen, **no
certificate warning of any kind**, and a padlock in Safari.

---

### Task 7: Wire the transport into the runtime

**Files:**
- Modify: `src/phice/runtime.py`
- Test: `tests/test_rtc.py` (append)

- [ ] **Step 1: Write the failing test — append to `tests/test_rtc.py`**

```python
async def test_runtime_publishes_an_offer_under_a_code(tmp_path, monkeypatch):
    """cert_mode and TLS are irrelevant in webrtc transport: the runtime must
    publish an offer and expose the code without minting any certificate."""
    import json as _json

    from phice.cursor_backend import FakeCursor
    from phice.paths import Paths
    from phice.runtime import Runtime

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    p = paths.pointer_json
    d = _json.loads(p.read_text())
    d["transport"] = "webrtc"
    d["signaling_url"] = "https://example.invalid"
    p.write_text(_json.dumps(d))

    published: dict = {}

    class FakeSignaling:
        def __init__(self, *a, **kw):
            pass

        async def publish_offer(self, code, offer):
            published["code"] = code
            published["offer"] = offer

        async def wait_for_answer(self, code, timeout=300.0, interval=1.0):
            await asyncio.sleep(3600)   # never answers, in this test

    monkeypatch.setattr("phice.runtime.SignalingClient", FakeSignaling)
    rt = Runtime(paths, FakeCursor(), 0, 0)
    task = asyncio.ensure_future(rt.start_webrtc())
    await asyncio.sleep(2.0)
    task.cancel()
    assert len(published.get("code", "")) == 6
    assert published["offer"]["type"] == "offer"
    assert rt.status.read()["pair_code"] == published["code"]
    await rt.rtc.close()
```

- [ ] **Step 2: Run it and watch it fail**

Run: `uv run pytest tests/test_rtc.py -q -k runtime`
Expected: FAIL, `AttributeError: 'Runtime' object has no attribute 'start_webrtc'`

- [ ] **Step 3: Modify `src/phice/runtime.py`**

Add to the imports:

```python
from .rtc import RTCTransport
from .signaling import SignalingClient, SignalingError, new_pairing_code
```

Add `pair_code: str = ""` to the `Status` dataclass, and include it in `Status.read()`.

Add these methods to `Runtime`:

```python
    async def start_webrtc(self) -> None:
        """Publish an offer under a short code and wait for the phone.

        Repeats: each pairing consumes its code, and a fresh offer must be
        published for the next phone.
        """
        client = SignalingClient(self.config.signaling_url)
        while True:
            self.rtc = RTCTransport(engine=self.engine,
                                    layout_json=self.paths.layout_json.read_text(),
                                    theme_css=self.paths.theme_css.read_text())
            offer = await self.rtc.create_offer()
            code = new_pairing_code()
            try:
                await client.publish_offer(code, offer)
            except SignalingError as e:
                log.error("could not reach the pairing service: %s", e)
                self.status.update(error=str(e))
                await asyncio.sleep(10)
                continue
            self.status.update(pair_code=code, error="")
            log.info("pairing code %s -- enter it at %s", code, self.config.signaling_url)
            try:
                answer = await client.wait_for_answer(code)
            except SignalingError:
                await self.rtc.close()
                continue          # code expired unused; mint a new one
            await self.rtc.accept_answer(answer)
            self.status.update(pair_code="")
            # Hold until the channel closes, then offer a fresh code.
            while self.rtc.pc.connectionState not in ("failed", "closed", "disconnected"):
                await asyncio.sleep(1.0)
            await self.rtc.close()
```

In `_main`, replace the certificate and TLS start block with a branch on transport:

```python
        if self.config.transport == "webrtc":
            self.http_port = await asyncio.to_thread(self.setup.start)
            log.info("webrtc transport; setup: http://127.0.0.1:%d/setup", self.http_port)
            await asyncio.gather(self.start_webrtc(), self._watch_config(), self._status_loop())
            return
```

placed immediately before the existing `if self.config.cert_mode == "tailscale":` line.

- [ ] **Step 4: Run it and watch it pass**

Run: `uv run pytest tests/test_rtc.py -q`
Expected: `6 passed`

- [ ] **Step 5: Push layout and theme edits over the channel**

Hot reload currently only pushes to the TLS server. The two handlers are
`_apply_layout` (`runtime.py:152`) and `_apply_theme` (`runtime.py:164`).

At the end of `_apply_layout`, after `await self.server.push_layout(layout)`:

```python
        if self.rtc:
            await self.rtc.push_layout(path.read_text())
```

At the end of `_apply_theme`, after `await self.server.push_theme_changed()`:

```python
        if self.rtc:
            await self.rtc.push_theme(path.read_text())
```

Add to `Runtime.__init__`, next to `self.tailnet`:

```python
        self.rtc: RTCTransport | None = None
```

- [ ] **Step 6: Run the whole suite**

Run: `uv run pytest -q && uv run ruff check .`
Expected: all pass, clean.

- [ ] **Step 7: Commit**

```bash
git add src/phice/runtime.py tests/test_rtc.py
git commit -m "feat: run the WebRTC transport from the runtime"
```

---

### Task 8: Show the pairing code and switch transport

**Files:**
- Modify: `src/phice/setup_server.py`, `src/phice/cli.py`

- [ ] **Step 1: Show the code on the setup page**

In `setup_server.py`, inside `do_GET`, before the `/setup` branch, add:

```python
                elif path == "/pair" and self._is_local():
                    code = outer._pair_code() if outer._pair_code else ""
                    body = (f"<!doctype html><meta charset=utf-8><title>Phice pairing</title>"
                            f"<style>{SETUP_CSS}"
                            f".code{{font-size:64px;letter-spacing:14px;text-align:center;"
                            f"margin:28px 0;color:#3ea6ff}}</style>"
                            f"<div class='card' style='max-width:460px;margin:0 auto'>"
                            f"<h1>Pair your phone</h1>"
                            f"<p class='muted'>Open <b>{outer._signaling_url()}</b> on your "
                            f"iPhone and enter this code.</p>"
                            f"<div class='code'>{code or '······'}</div>"
                            f"<p class='muted'>The code changes every five minutes until a "
                            f"phone connects. Reload for the current one.</p></div>")
                    self._send(200, body.encode(), "text/html; charset=utf-8")
```

Extend `SetupServer.__init__` with `pair_code: Callable[[], str] | None = None` and
`signaling_url: Callable[[], str] | None = None`, storing them as
`self._pair_code` and `self._signaling_url`.

In `runtime.py` where `SetupServer` is constructed, pass:

```python
                                 pair_code=lambda: self.status.read()["pair_code"],
                                 signaling_url=lambda: self.config.signaling_url,
```

- [ ] **Step 2: Add a CLI verb to switch transport**

In `cli.py`, add before `_plist`:

```python
def cmd_webrtc(args) -> int:
    """Switch to the hosted page + WebRTC transport."""
    paths = _paths(args)
    data = json.loads(paths.pointer_json.read_text())
    data["transport"] = "webrtc"
    if args.signaling_url:
        data["signaling_url"] = args.signaling_url
    paths.pointer_json.write_text(json.dumps(data, indent=2) + "\n")
    print(f"transport set to 'webrtc' in {paths.pointer_json}\n"
          f"phone page: {data['signaling_url']}\n"
          f"pairing code: http://127.0.0.1:{args.http_port}/pair\n"
          "Restart the app for this to take effect: phice install")
    return 0
```

Register it, and give it its one option, by replacing the loop entry list addition with:

```python
    wrtc = sub.add_parser("webrtc", help="use the hosted page and WebRTC transport")
    wrtc.add_argument("--signaling-url", default=None)
    wrtc.set_defaults(func=cmd_webrtc)
```

placed just after the `run` subparser block.

- [ ] **Step 3: Verify**

Run: `uv run pytest -q && uv run ruff check . && uv run phice --help`
Expected: all pass, and `webrtc` appears in the command list.

- [ ] **Step 4: Commit**

```bash
git add src/phice/setup_server.py src/phice/cli.py
git commit -m "feat: pairing code page and 'phice webrtc'"
```

---

### Task 9: End-to-end on real hardware

**Files:** none (verification task)

- [ ] **Step 1: Switch transport and restart**

```bash
uv run phice webrtc --signaling-url https://YOUR-PROJECT.vercel.app
uv run phice install
sleep 5
curl -s http://127.0.0.1:8080/debug/cursor | python3 -m json.tool
```
Expected: a `pair_code` of six characters, and no certificate work in the log.

- [ ] **Step 2: Pair from the phone**

Open `https://YOUR-PROJECT.vercel.app` on the iPhone — **no certificate warning**.
Enter the code, tap **Connect**, then **Start**, and allow motion access.

Expected: the buttons appear, styled by *your* `theme.css`, pushed from the Mac.

- [ ] **Step 3: Confirm the pointer works**

Tap POWER and point. Then:
```bash
curl -s http://127.0.0.1:8080/debug/cursor | python3 -m json.tool
```
Expected: `"connected": true`, `"phase": "on"`, and a moving `x`/`y`.

- [ ] **Step 4: Confirm hot reload still works over the channel**

Edit a colour in `~/Library/Application Support/Phice/theme.css`, save, and watch the
phone change within two seconds. Move a button in `layout.json` and watch it move.

- [ ] **Step 5: Confirm it works with the phone on cellular**

Turn Wi-Fi **off** on the iPhone, reload the page, pair again. Expected: it connects
over 5G, with the Mac still on Wi-Fi. This is the case that was impossible before.

If it fails here but works on Wi-Fi, direct peer-to-peer was blocked and a TURN relay
would be required — record which network, and treat it as the known limitation below.

- [ ] **Step 6: Commit the documentation**

Update `README.md` so the hosted page is the primary path, and add to `CLAUDE.md`:

```markdown
- **WebRTC is the default transport.** Signaling is two HTTP messages against Vercel
  (non-trickle ICE), then a direct DataChannel. Motion data, layout and theme never
  touch the server. The TLS transport remains for local-only use and is what the
  server tests exercise.
- **Layout and theme are pushed over the data channel**, not fetched over HTTP. The
  hosted page ships with no design of its own.
```

```bash
git add -A && git commit -m "docs: hosted pairing is the primary path"
```

---

## Definition of done

1. `uv run pytest -q` passes, including `tests/test_rtc.py` and `tests/test_signaling.py`.
2. `uv run ruff check .` is clean.
3. The Vercel deployment serves the page over HTTPS with no warning on the iPhone.
4. `POST`/`GET` on `/api/offer` and `/api/answer` behave: `200`, stored value, `404`, `400`.
5. Entering the code on the phone establishes a DataChannel and the cursor moves.
6. Editing `theme.css` or `layout.json` changes the phone within two seconds.
7. Pairing works with the phone on cellular and the Mac on Wi-Fi.
8. The TLS transport still works when `transport` is set back to `tls`.

## Known limitations

**Networks that isolate clients may block the direct path.** WebRTC would then need a
TURN relay, which Vercel cannot provide. Options when that happens: a free-tier TURN
service, a small `coturn` VPS, or falling back to `transport: tls` on that network.

**The Vercel Hobby tier is non-commercial.** Fine for personal use; a commercial
product needs the paid tier.

**`av` is a hard dependency of `aiortc`** and adds roughly 40 MB to the bundle even
though no audio or video is used.

## Out of scope

TURN relay provisioning, more than one phone at a time, reconnect-without-recode
(a remembered device token over WebRTC), and an auto-updater for the Mac app.
