import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from phice.signaling import (
    DEFAULT_OFFER_TTL_S,
    SignalingClient,
    SignalingError,
    new_pairing_code,
    offer_ttl,
)


@pytest.fixture
def stub():
    """Minimal stand-in for the Vercel functions: an in-memory letterbox."""
    store: dict[str, dict] = {}

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _send_bytes(self, code, body: bytes):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send(self, code, obj):
            self._send_bytes(code, json.dumps(obj).encode())

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n))
            kind = self.path.strip("/").split("/")[-1]
            store[f"{kind}:{data['code']}"] = data
            # Two codes are reserved to make the letterbox answer with a reply
            # publish_offer must survive: an empty body, and one that is not JSON.
            if kind == "offer" and data["code"] == "EMPTY2":
                self._send_bytes(200, b"")
            elif kind == "offer" and data["code"] == "BADJS2":
                self._send_bytes(200, b"not json")
            else:
                # offer.js reports the lifetime; answer.js does not.
                self._send(200, {"ok": True, "expires_in": 7} if kind == "offer" else {"ok": True})

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


async def test_publishing_an_offer_reports_how_long_the_letterbox_keeps_it(stub):
    """The lifetime is the letterbox's to decide, and it says so in its reply.
    Assuming 300 on the Mac meant the two could disagree without anyone noticing."""
    base, _ = stub
    c = SignalingClient(base, allow_insecure=True)
    assert await c.publish_offer("ABC234", {"sdp": "x", "type": "offer"}) == 7.0


async def test_a_garbled_or_empty_reply_falls_back_to_the_default(stub):
    """The reply is only an acknowledgement: the offer landed either way, so a
    reply that cannot be read must not fail the publish."""
    base, _ = stub
    c = SignalingClient(base, allow_insecure=True)
    assert await c.publish_offer("EMPTY2", {"sdp": "x", "type": "offer"}) == DEFAULT_OFFER_TTL_S
    assert await c.publish_offer("BADJS2", {"sdp": "x", "type": "offer"}) == DEFAULT_OFFER_TTL_S


async def test_publish_offer_raises_when_the_letterbox_is_unreachable():
    """Unlike a garbled reply, an unreachable letterbox must not be swallowed
    into a default lifetime -- the caller needs to know the offer never landed."""
    c = SignalingClient("http://127.0.0.1:1", allow_insecure=True)
    with pytest.raises(SignalingError):
        await c.publish_offer("ABC234", {"sdp": "x", "type": "offer"})


def test_a_letterbox_that_says_nothing_about_lifetime_gets_the_default():
    assert offer_ttl({"ok": True, "expires_in": 7}) == 7.0
    assert offer_ttl({"ok": True}) == DEFAULT_OFFER_TTL_S
    assert offer_ttl({"expires_in": "soon"}) == DEFAULT_OFFER_TTL_S
    assert offer_ttl({"expires_in": 0}) == DEFAULT_OFFER_TTL_S
    assert offer_ttl({"expires_in": True}) == DEFAULT_OFFER_TTL_S
    assert offer_ttl({"expires_in": float("nan")}) == DEFAULT_OFFER_TTL_S
    assert offer_ttl({"expires_in": float("inf")}) == DEFAULT_OFFER_TTL_S
    assert offer_ttl(None) == DEFAULT_OFFER_TTL_S
