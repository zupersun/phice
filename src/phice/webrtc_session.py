"""Publishing an offer under a short code, and serving whoever answers it.

Split out of the runtime, which was past this project's own file length limit
and had no business also owning a signaling loop. It takes the runtime rather
than a dozen separate pieces, because the loop genuinely needs most of it --
pretending otherwise with eight constructor arguments would be decoration.
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import TYPE_CHECKING

from .rtc import RTCTransport
from .signaling import SignalingClient, SignalingError, new_pairing_code

if TYPE_CHECKING:
    from .runtime import Runtime

log = logging.getLogger("phice")


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
    verifies the peers by DTLS fingerprint, which is the whole reason this
    transport exists.
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
                                layout_json=rt.paths.layout_json.read_text(),
                                theme_css=rt.paths.theme_css.read_text(),
                                accessibility=lambda: rt.status.read()["accessibility"],
                                ice_servers=(rt.rtc_ice_servers
                                             if rt.rtc_ice_servers is not None
                                             else ice))
        offer = await rt.rtc.create_offer()
        # Keep the same code for the life of the process and republish a fresh
        # offer under it. Minting a new one after every disconnect meant the
        # user had to walk back to the Mac each time -- and the page's
        # remembered code was always the dead one.
        code = rt.pairing.code or new_pairing_code()
        rt.pairing.code = code
        try:
            await client.publish_offer(code, offer)
        except SignalingError as e:
            log.error("could not reach the pairing service: %s", e)
            rt.status.update(error=str(e))
            await rt.rtc.close()
            await asyncio.sleep(10)
            continue
        rt.status.update(pair_code=code, error="")
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

