"""WebRTC transport: a DataChannel peer that feeds the existing engine.

The wire format is unchanged -- frames go through protocol.parse_client_message
exactly as the WebSocket transport does -- so this swaps how bytes arrive and
nothing else.
"""
from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from typing import Any

from aiortc import (
    RTCConfiguration,
    RTCDataChannel,
    RTCIceServer,
    RTCPeerConnection,
    RTCSessionDescription,
)

from .engine import PointerEngine
from .paths import client_version
from .protocol import (
    Bye,
    ClientLog,
    Hello,
    Ping,
    ProtocolError,
    SensorPacket,
    layout_message,
    parse_client_message,
    pong_message,
    theme_chunks,
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
                 ice_servers: tuple | None = None,
                 accessibility: Callable[[], bool] | None = None):
        self.engine = engine
        self._accessibility = accessibility or (lambda: False)
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
        self.channel: RTCDataChannel | None = None   # sensor packets, lossy
        self.ctl: RTCDataChannel | None = None       # control, reliable
        self._tick: asyncio.Task | None = None
        self._closed = False
        # Counters, because a silently dropped frame is indistinguishable
        # from a phone that never sent one.
        self.frames = 0
        self.bad_frames = 0
        self.last_error = ""
        self.client_name = ""
        self.client_caps = ""
        self.client_stale = False
        self.hz = 0.0
        self._last_phase = "disconnected"

    # ----- signaling --------------------------------------------------------

    async def create_offer(self) -> dict[str, str]:
        # Two channels, because the traffic has two opposite requirements.
        #
        # Sensor packets are worthless once stale: at 60 Hz, retransmitting a
        # lost one delivers an old position late and blocks the fresh ones
        # behind it. Unreliable and unordered is right for them.
        #
        # Layout, theme and state must arrive. The theme alone is ~12 KB, which
        # fragments across nine SCTP chunks, and on an unreliable channel losing
        # any one of them discards the whole message -- the page then renders
        # unstyled buttons on a black background with no error anywhere. That
        # was intermittent for exactly as long as it took to notice.
        self.channel = self.pc.createDataChannel("phice", ordered=False,
                                                 maxRetransmits=0)
        self.ctl = self.pc.createDataChannel("phice-ctl", ordered=True)
        self._wire_channel(self.channel)
        self._wire_ctl(self.ctl)

        @self.pc.on("connectionstatechange")
        async def _on_state() -> None:
            log.info("rtc connection state: %s", self.pc.connectionState)
            if self.pc.connectionState in ("failed", "closed", "disconnected"):
                self.engine.disconnected()

        await self.pc.setLocalDescription(await self.pc.createOffer())
        await gather_complete(self.pc)
        sdp = self.pc.localDescription.sdp
        # Say what was actually gathered. "relay" missing means the phone can only
        # be reached on a shared network, and that is worth knowing before a user
        # discovers it by failing to connect.
        kinds: dict[str, int] = {}
        for line in sdp.splitlines():
            if line.startswith("a=candidate"):
                k = line.split()[7]
                kinds[k] = kinds.get(k, 0) + 1
        log.info("ICE candidates gathered: %s%s", kinds,
                 "" if "relay" in kinds else "  <- NO RELAY: same-network only")
        return {"sdp": sdp, "type": self.pc.localDescription.type}

    async def accept_answer(self, answer: dict[str, Any]) -> None:
        await self.pc.setRemoteDescription(
            RTCSessionDescription(sdp=answer["sdp"], type=answer["type"]))

    # ----- channel ----------------------------------------------------------

    def _wire_ctl(self, ctl: RTCDataChannel) -> None:
        """The reliable half: everything that must arrive."""
        @ctl.on("open")
        def _on_open() -> None:
            log.info("control channel open")
            self.engine.connected()
            # Without this the phone is blind: no status LED, no recenter
            # animation, no reaction to a press. The TLS transport has always
            # done it; leaving it out here made every button look dead even
            # though the engine was reacting.
            self.engine.on_change = self.notify_state
            self._push_setup(ctl)
            # Once more after a beat. The Mac sends the instant its own end
            # opens, which can be before the page has attached its listener --
            # and a message dispatched to nobody is gone, with no error at
            # either end. A phone that got everything simply renders it again;
            # one that missed the theme stops showing unstyled buttons and a
            # dead status light.
            asyncio.get_event_loop().call_later(
                1.2, lambda: self._push_setup(ctl, again=True))
            if self._tick is None:
                self._tick = asyncio.ensure_future(self._tick_loop())

        @ctl.on("message")
        def _on_ctl(message: Any) -> None:
            if isinstance(message, str):
                self._handle(message, ctl)

        @ctl.on("close")
        def _on_close() -> None:
            log.info("control channel closed")
            self.engine.on_change = None
            self.engine.disconnected()

    def _wire_channel(self, channel: RTCDataChannel) -> None:
        @channel.on("open")
        def _on_open() -> None:
            log.info("data channel open")
            if self._tick is None:
                self._tick = asyncio.ensure_future(self._tick_loop())

        @channel.on("message")
        def _on_message(message: Any) -> None:
            if isinstance(message, str):
                self._handle(message, channel)

        @channel.on("close")
        def _on_data_close() -> None:
            log.info("data channel closed")

    def _handle(self, message: str, reply: RTCDataChannel) -> None:
        """One inbound frame, from whichever channel carried it."""
        self.frames += 1
        try:
            parsed = parse_client_message(message)
        except ProtocolError as e:
            self.bad_frames += 1
            self.last_error = str(e)
            # A bad frame never kills the session, but it must not be silent
            # either: log the first few so a broken client is visible.
            if self.bad_frames <= 3:
                log.warning("dropping malformed frame: %s -- %s", e, message[:160])
            return
        if isinstance(parsed, SensorPacket):
            self.hz = parsed.hz
            self.engine.handle(parsed)
        elif isinstance(parsed, Ping):
            reply.send(pong_message())
        elif isinstance(parsed, Bye):
            self.engine.disconnected()
        elif isinstance(parsed, ClientLog):
            # Safari's console cannot be reached from here, so this is the only
            # way the page can say what went wrong on it.
            log.warning("phone says: %s", parsed.msg)
        elif isinstance(parsed, Hello):
            # Pairing already happened out of band, via the code. The hello
            # only reports what the phone can do, and which client it is.
            self.client_name = parsed.name
            self.client_caps = parsed.caps
            log.info("phone connected: %s (caps: %s)", parsed.name, parsed.caps or "none")
            want = client_version()
            got = next((c[1:] for c in parsed.caps.split(",") if c.startswith("v")), "")
            self.client_stale = bool(want) and got != want
            if self.client_stale:
                log.warning("the phone is running client %s but this Mac ships %s: it has "
                            "a cached copy of the page", got or "(unversioned)", want)

    def _push_setup(self, ctl: RTCDataChannel, again: bool = False) -> None:
        """Everything the page needs to draw itself: layout, theme, status."""
        if ctl.readyState != "open":
            return
        try:
            ctl.send(layout_message(json.loads(self.layout_json)))
            for part in theme_chunks(self.theme_css):
                ctl.send(part)
            self.notify_state()
            if again:
                log.debug("re-sent layout and theme")
        except Exception:
            log.warning("could not push the layout and theme", exc_info=True)

    def notify_state(self) -> None:
        """Tell the phone what the engine is doing.

        Called on every engine change, so it must be cheap and must never raise:
        the engine calls it from inside its own state transitions.
        """
        # Exact transitions, not samples. The status poll runs every half second,
        # so a hold that completes and restarts inside one tick is invisible to
        # it -- which is the window a double flash would hide in.
        phase = self.engine.phase.value
        if phase != self._last_phase:
            log.info("phase %s -> %s", self._last_phase, phase)
            self._last_phase = phase
        ch = self.ctl
        if ch is None or ch.readyState != "open":
            return
        try:
            ch.send(self.engine.state_message(self._accessibility()))
        except Exception:  # a closing channel must not break an engine transition
            log.debug("state push failed", exc_info=True)

    async def _tick_loop(self) -> None:
        """Time-based engine transitions still need driving -- see CLAUDE.md #1."""
        last_recenter = -1.0
        try:
            while not self._closed:
                self.engine.tick()
                active = self.engine.phase.value in ("on", "hold", "held")
                # The recenter bar is a continuous value, so it cannot come from
                # on_change alone: push it while the hold is running.
                if self.engine.phase.value == "hold":
                    prog = round(self.engine.recenter_progress(), 2)
                    if prog != last_recenter:
                        last_recenter = prog
                        self.notify_state()
                else:
                    last_recenter = -1.0
                await asyncio.sleep(1 / (TICK_HZ_ACTIVE if active else TICK_HZ_IDLE))
        except asyncio.CancelledError:
            pass

    async def push_layout(self, layout_json: str) -> None:
        self.layout_json = layout_json
        if self.ctl and self.ctl.readyState == "open":
            self.ctl.send(layout_message(json.loads(layout_json)))

    async def push_theme(self, theme_css: str) -> None:
        self.theme_css = theme_css
        if self.ctl and self.ctl.readyState == "open":
            for part in theme_chunks(theme_css):
                self.ctl.send(part)

    @property
    def is_open(self) -> bool:
        """The control channel is the session: without it the phone has no
        layout, no theme and no status, whatever the lossy one is doing."""
        return self.ctl is not None and self.ctl.readyState == "open"

    async def close(self) -> None:
        self._closed = True
        if self._tick:
            self._tick.cancel()
        self.engine.on_change = None
        self.engine.disconnected()
        # Shielded: aiortc's close() sets its internal "closed" future as its
        # very first step and only resolves it at the very end. If whoever
        # called us gets cancelled while this await is in flight, an
        # unshielded pc.close() would abandon that future half-set -- and
        # every later close() on the same pc (there is always at least one
        # more, from the caller that is tearing this transport down) would
        # then await a future nobody will ever resolve, forever. Shielding
        # lets the cancellation still propagate to our caller while this
        # cleanup finishes in the background.
        await asyncio.shield(self.pc.close())
