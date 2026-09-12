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

    async def fetch_ice_servers(self) -> list[dict] | None:
        """The relay configuration both peers must share.

        Returns None if the service cannot be reached, so the caller falls back
        to its own default rather than failing to start. Mismatched ICE lists
        gather candidates that cannot pair, so this is the single source.
        """
        try:
            body = await asyncio.to_thread(self._get_sync, "/api/ice", "")
        except SignalingError:
            return None
        if not body or not isinstance(body.get("iceServers"), list):
            return None
        return body["iceServers"]

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
