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

from aiortc import (
    RTCConfiguration,
    RTCDataChannel,
    RTCIceServer,
    RTCPeerConnection,
    RTCSessionDescription,
)

from .engine import PointerEngine
from .protocol import (
    Bye,
    Hello,
    Ping,
    ProtocolError,
    SensorPacket,
    layout_message,
    parse_client_message,
    pong_message,
    theme_message,
)

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
    except TimeoutError:
        log.warning("ICE gathering did not complete in %.0fs; publishing anyway", timeout)


class RTCTransport:
    """One peer connection, one DataChannel, wired to the engine."""

    #: Public STUN, needed to discover a routable address when the phone is not on
    #: the same network. aiortc defaults to this too, but naming it lets tests turn
    #: it off: on loopback the round trip costs five seconds per peer and buys
    #: nothing.
    DEFAULT_ICE_SERVERS = ("stun:stun.l.google.com:19302",)

    def __init__(self, engine: PointerEngine, layout_json: str, theme_css: str,
                 ice_servers: tuple | None = None):
        self.engine = engine
        self.layout_json = layout_json
        self.theme_css = theme_css
        entries = self.DEFAULT_ICE_SERVERS if ice_servers is None else ice_servers
        servers = []
        for e in entries:
            # A bare string is a STUN url; a dict may also carry TURN credentials.
            if isinstance(e, str):
                servers.append(RTCIceServer(urls=e))
            else:
                servers.append(RTCIceServer(urls=e["urls"], username=e.get("username"),
                                            credential=e.get("credential")))
        config = RTCConfiguration(iceServers=servers)
        self.pc = RTCPeerConnection(configuration=config)
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
