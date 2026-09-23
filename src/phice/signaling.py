"""Finding each other: the pairing letterbox, and the loop that uses it.

These were two modules and were never separately useful -- one posts an offer
under a short code, the other decides when to do that and waits for the answer.
Together they are the whole of "how a phone finds this Mac".

The client is deliberately the dumbest thing that works: two POSTs and two GETs.
Non-trickle ICE means the exchange is one offer and one answer, so there is no
need for a WebSocket -- which matters, because Vercel's free tier cannot hold
one open.
"""
from __future__ import annotations

import asyncio
import json
import logging
import math
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from typing import TYPE_CHECKING

from .rtc import RTCTransport

if TYPE_CHECKING:
    from .runtime import Runtime

log = logging.getLogger("phice.signaling")

# No 0/O/1/I/L: these are the characters people misread and mistype.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 6
HTTP_TIMEOUT = 10.0

#: What web/api/offer.js keeps an offer for, used only if the letterbox's reply
#: does not say. The reply is authoritative: the two must never disagree.
DEFAULT_OFFER_TTL_S = 300.0


def offer_ttl(body: dict | None) -> float:
    """The lifetime a letterbox reply promises, or the default if it is silent."""
    value = (body or {}).get("expires_in")
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or value <= 0):
        return DEFAULT_OFFER_TTL_S
    return float(value)


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

    def _post_sync(self, path: str, payload: dict) -> dict:
        body = json.dumps(payload).encode()
        req = urllib.request.Request(f"{self.base}{path}", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
                raw = r.read()
        except (urllib.error.URLError, OSError) as e:
            raise SignalingError(f"POST {path} failed: {e}") from e
        # A POST's body is only an acknowledgement: a request that failed still
        # raises above, so a garbled one here can safely fall back to the default.
        try:
            reply = json.loads(raw) if raw else {}
        except ValueError:
            reply = {}
        return reply if isinstance(reply, dict) else {}

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

    async def publish_offer(self, code: str, offer: dict) -> float:
        """Post the offer under the code. Returns how many seconds the letterbox
        will keep it, which is the letterbox's decision, not ours."""
        reply = await asyncio.to_thread(self._post_sync, "/api/offer", {"code": code, **offer})
        return offer_ttl(reply)

    async def fetch_offer(self, code: str) -> dict | None:
        return await asyncio.to_thread(self._get_sync, "/api/offer", code)

    async def publish_answer(self, code: str, answer: dict) -> None:
        await asyncio.to_thread(self._post_sync, "/api/answer", {"code": code, **answer})

    async def fetch_answer(self, code: str) -> dict | None:
        return await asyncio.to_thread(self._get_sync, "/api/answer", code)

    async def wait_for_answer(self, code: str, timeout: float = DEFAULT_OFFER_TTL_S,
                              interval: float = 1.0, expires_at: float | None = None,
                              clock: Callable[[], float] = time.time) -> dict:
        """Poll until the phone answers. Polling, not streaming, because the
        whole exchange is two messages and serverless cannot hold a socket.

        Two clocks, on purpose. `timeout` runs on the loop's monotonic clock,
        which stops while the Mac sleeps; `expires_at` is compared against a
        wall clock, which does not. After a sleep the letterbox has dropped the
        offer, and only the wall clock knows.
        """
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while loop.time() < deadline:
            if expires_at is not None and clock() >= expires_at:
                raise SignalingError("the offer expired at the letterbox")
            got = await self.fetch_answer(code)
            if got:
                return got
            await asyncio.sleep(interval)
        raise SignalingError(f"waiting for the phone timed out after {timeout:.0f}s")


# ----- the publish loop ------------------------------------------------------

@dataclass
class Pairing:
    """The pairing code and the wait for an answer, shared between this loop and
    whoever asks for a fresh code from the panel.

    A small named thing rather than three loose attributes on the runtime: they
    are only meaningful together, and `rotate` in particular has to be read in
    the same breath as `waiter` -- it is what tells a cancellation of that wait
    apart from the whole task being shut down.
    """

    #: Kept for the life of the process. Minting a new one after every
    #: disconnect sent the user back to the Mac each time, and the page's
    #: remembered code was always the dead one.
    code: str = ""
    waiter: asyncio.Task | None = None
    rotate: bool = False


def ice_servers(rt: Runtime) -> tuple | None:
    """Configured ICE servers, or None to use the default STUN.

    A relay matters when both peers sit behind symmetric NAT -- a phone on
    carrier NAT talking to a Mac on a university network cannot hole-punch,
    and STUN alone discovers addresses neither side can reach.
    """
    cfg = rt.config.ice_servers
    return tuple(cfg) if cfg else None


async def run(rt: Runtime) -> None:
    """Publish an offer under a short code and wait for a phone to answer.

    Loops: a pairing code is single use, so once a phone connects the next one
    needs a fresh offer. No certificate is involved at any point -- WebRTC
    verifies the peers by DTLS fingerprint, which is what lets a plain hosted
    page reach the motion sensors and the Mac without anything installed.
    """
    client = SignalingClient(rt.config.signaling_url)
    while True:
        ice = ice_servers(rt)
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
        rt.rtc = RTCTransport(engine=rt.engine,
                              layout=rt.layout.to_dict(),
                              theme_css=rt.paths.theme_css.read_text(),
                              accessibility=lambda: rt.status.read()["accessibility"],
                              record=rt.record,
                              ice_servers=(rt.rtc_ice_servers
                                           if rt.rtc_ice_servers is not None
                                           else ice))
        # Mint and show the code before gathering candidates, not after. ICE
        # gathering takes seconds, and minting afterwards meant "new code" sat
        # there doing nothing visible for all of them. The phone may now ask for
        # an offer that is still being built, which is why the page retries
        # rather than failing on the first miss.
        #
        # The code itself lives for the whole process: minting a new one after
        # every disconnect sent the user back to the Mac each time, and the
        # page's remembered code was always the dead one.
        code = rt.pairing.code or new_pairing_code()
        rt.pairing.code = code
        rt.status.update(pair_code=code, error="")

        offer = await rt.rtc.create_offer()
        try:
            await client.publish_offer(code, offer)
        except SignalingError as e:
            log.error("could not reach the pairing service: %s", e)
            rt.status.update(error=str(e))
            await rt.rtc.close()
            await asyncio.sleep(10)
            continue
        log.info("pairing code %s -- enter it at %s/app", code, rt.config.signaling_url)
        rt.pairing.waiter = asyncio.ensure_future(client.wait_for_answer(code))
        try:
            answer = await rt.pairing.waiter
        except SignalingError:
            await rt.rtc.close()
            continue            # the code expired unused; mint another
        except asyncio.CancelledError:
            # Two very different things arrive here: the panel asking for a
            # new code, and this whole task being shut down. Swallowing both
            # made the loop immortal -- the app could not quit and the test
            # suite hung at random.
            await rt.rtc.close()
            if not rt.pairing.rotate:
                raise
            rt.pairing.rotate = False
            continue
        finally:
            rt.pairing.waiter = None
            rt.pairing.rotate = False   # a stale request must not eat a shutdown
        await rt.rtc.accept_answer(answer)
        while rt.rtc.pc.connectionState not in ("failed", "closed", "disconnected"):
            await asyncio.sleep(1.0)
        await rt.rtc.close()

