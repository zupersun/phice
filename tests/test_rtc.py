"""Two aiortc peers connecting in-process: no network, no phone, no Vercel."""
import asyncio
import json

import pytest
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription

from phice.config import PointerConfig
from phice.cursor_backend import FakeCursor
from phice.engine import PointerEngine
from phice.rtc import RTCTransport, gather_complete


def _no_stun() -> RTCConfiguration:
    """Loopback peers need no STUN, and asking for it costs five seconds each."""
    return RTCConfiguration(iceServers=[])


async def _connect(transport: RTCTransport) -> tuple[RTCPeerConnection, object]:
    """Play the part of the phone: take the offer, answer it, return the channel."""
    offer = await transport.create_offer()
    phone = RTCPeerConnection(configuration=_no_stun())
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
    # NB: pressing `power` no longer starts the pointer. Any button press wakes it
    # and is consumed; power taps off and holds to recenter.
    # No STUN: these peers only ever talk over loopback, and the round trip
    # costs five seconds per connection while discovering nothing useful.
    t = RTCTransport(engine=engine, layout_json='{"version":1,"buttons":[]}',
                     theme_css="body{}", ice_servers=())
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
        # Wake with a left press (consumed, not a click), then turn right.
        for seq, (alpha, left, lc) in enumerate(
                [(0.0, 1, 1), (0.0, 0, 1)] + [(350.0, 0, 1)] * 90, start=1):
            channel.send(json.dumps({
                "t": "s", "seq": seq, "ts": seq / 60, "o": [alpha, 0, 0],
                "rr": [10, 0, 0], "g": [0, 0, 9.8],
                "b": {"left": left, "right": 0, "scroll": 0, "power": 0},
                "c": {"left": lc, "right": 0, "scroll": 0, "power": 0},
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
    phone = RTCPeerConnection(configuration=_no_stun())
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
        "b": {"left": 1}, "c": {"left": 1}, "sd": 0}))
    await asyncio.sleep(0.2)
    await phone.close()
    await asyncio.sleep(0.5)
    assert transport.cursor.held == set()
    await transport.close()
