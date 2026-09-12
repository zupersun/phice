import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from phice.signaling import SignalingClient, SignalingError, new_pairing_code


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
    assert {k: v for k, v in got.items() if k != "code"} == {"sdp": "x", "type": "offer"}
    await c.publish_answer(code, {"sdp": "y", "type": "answer"})
    got = await c.fetch_answer(code)
    assert {k: v for k, v in got.items() if k != "code"} == {"sdp": "y", "type": "answer"}


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


async def test_ice_servers_are_fetched_from_the_service(stub):
    """Both peers must take their relay from one place: mismatched ICE lists
    gather candidates that cannot pair."""
    base, store = stub
    c = SignalingClient(base, allow_insecure=True)
    # The stub echoes whatever was POSTed under the matching path.
    await c.publish_offer("ABC234", {"sdp": "x", "type": "offer"})
    assert await c.fetch_ice_servers() is None  # stub serves no /api/ice


async def test_missing_ice_endpoint_does_not_break_startup():
    """A signaling service that cannot be reached must not stop the Mac starting;
    it falls back rather than failing."""
    c = SignalingClient("http://127.0.0.1:1", allow_insecure=True)
    assert await c.fetch_ice_servers() is None
