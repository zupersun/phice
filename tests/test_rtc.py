"""Two aiortc peers connecting in-process: no network, no phone, no Vercel."""
import asyncio
import json

import pytest
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription

from phice import signaling
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
        # Two channels now: the lossy one for sensor packets and the reliable
        # one for anything that must arrive. The session begins with control.
        channels[channel.label] = channel
        if channel.label == "phice-ctl" and not opened.done():
            opened.set_result(channel)

    await phone.setRemoteDescription(RTCSessionDescription(**offer))
    answer = await phone.createAnswer()
    await phone.setLocalDescription(answer)
    await gather_complete(phone)
    await transport.accept_answer({"sdp": phone.localDescription.sdp,
                                   "type": phone.localDescription.type})
    await asyncio.wait_for(opened, timeout=10)
    return phone, channels.get("phice", channels["phice-ctl"])


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


async def test_runtime_publishes_an_offer_under_a_code(tmp_path, monkeypatch):
    """In webrtc transport the runtime must publish an offer and expose the code
    without minting any certificate: the whole point is that none is needed."""
    import json as _json

    from phice.paths import Paths
    from phice.runtime import Runtime

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    d = _json.loads(paths.pointer_json.read_text())
    d["transport"] = "webrtc"
    d["signaling_url"] = "https://example.invalid"
    paths.pointer_json.write_text(_json.dumps(d))

    published: dict = {}

    class FakeSignaling:
        def __init__(self, *a, **kw):
            pass

        async def fetch_ice_servers(self):
            return None  # no relay in this test; loopback needs none

        async def publish_offer(self, code, offer):
            published["code"] = code
            published["offer"] = offer

        async def wait_for_answer(self, code, timeout=300.0, interval=1.0):
            await asyncio.sleep(3600)  # never answers, in this test

    monkeypatch.setattr("phice.signaling.SignalingClient", FakeSignaling)
    rt = Runtime(paths, FakeCursor(), 0, 0)
    rt.rtc_ice_servers = ()  # loopback: no STUN round trip
    task = asyncio.ensure_future(signaling.run(rt))
    try:
        for _ in range(60):
            if "code" in published:
                break
            await asyncio.sleep(0.1)
        assert len(published.get("code", "")) == 6, "a six character pairing code"
        assert published["offer"]["type"] == "offer"
        assert "a=candidate" in published["offer"]["sdp"], "non-trickle: candidates included"
        assert rt.status.read()["pair_code"] == published["code"]
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        if rt.rtc:
            await rt.rtc.close()


async def test_the_pairing_code_survives_a_reconnect(tmp_path, monkeypatch):
    """Minting a new code after every disconnect sent the user back to the Mac
    each time, and made the page's remembered code always the dead one."""
    import json as _json

    from phice.cursor_backend import FakeCursor
    from phice.paths import Paths
    from phice.runtime import Runtime

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    d = _json.loads(paths.pointer_json.read_text())
    d["transport"] = "webrtc"
    d["signaling_url"] = "https://example.invalid"
    paths.pointer_json.write_text(_json.dumps(d))

    codes: list[str] = []

    class FakeSignaling:
        def __init__(self, *a, **kw):
            pass

        async def fetch_ice_servers(self):
            return None

        async def publish_offer(self, code, offer):
            codes.append(code)

        async def wait_for_answer(self, code, timeout=300.0, interval=1.0):
            # Fail immediately so the loop mints the next offer straight away.
            from phice.signaling import SignalingError
            raise SignalingError("timed out")

    monkeypatch.setattr("phice.signaling.SignalingClient", FakeSignaling)
    rt = Runtime(paths, FakeCursor(), 0, 0)
    rt.rtc_ice_servers = ()
    task = asyncio.ensure_future(signaling.run(rt))
    try:
        for _ in range(80):
            if len(codes) >= 2:
                break
            await asyncio.sleep(0.1)
        assert len(codes) >= 2, "expected the loop to publish more than one offer"
        assert len(set(codes)) == 1, f"the code must not change between offers: {codes}"
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        if rt.rtc:
            await rt.rtc.close()


async def test_the_phone_is_told_what_the_engine_did(transport):
    """A press that the Mac acts on but never acknowledges looks identical to a
    press that was dropped: no LED, no recenter bar, nothing. The phone drives
    every visual from these messages."""
    states: list[dict] = []
    phone = RTCPeerConnection(configuration=_no_stun())
    opened = asyncio.get_running_loop().create_future()

    @phone.on("datachannel")
    def on_channel(channel):
        @channel.on("message")
        def on_message(msg):
            m = json.loads(msg)
            if m["t"] == "state":
                states.append(m)

        # aiortc fires `datachannel` once the channel is already open, so the
        # "open" event may never arrive for it.
        if not opened.done():
            opened.set_result(channel)

    offer = await transport.create_offer()
    await phone.setRemoteDescription(RTCSessionDescription(**offer))
    await phone.setLocalDescription(await phone.createAnswer())
    await gather_complete(phone)
    await transport.accept_answer({"sdp": phone.localDescription.sdp,
                                   "type": phone.localDescription.type})
    try:
        channel = await asyncio.wait_for(opened, timeout=10)
        for seq in range(1, 6):   # a real phone streams; one packet can race the open
            channel.send(json.dumps({
                "t": "s", "seq": seq, "ts": seq / 60, "o": [0, 0, 0], "rr": [0, 0, 0],
                "g": [0, 0, 9.8], "b": {"left": 1}, "c": {"left": 1}, "sd": 0}))
            await asyncio.sleep(0.05)
        await asyncio.sleep(0.3)
        phases = [s["phase"] for s in states]
        assert phases[0] == "off", "the first state says the pointer is idle"
        assert "on" in phases, f"a press must be acknowledged, got {phases}"
        assert states[-1]["ui"]["recenter_ms"] > 0, "the phone times its own animation"
    finally:
        await phone.close()
        await transport.close()


async def test_status_says_connected_while_a_phone_is_on_the_data_channel(tmp_path, monkeypatch):
    """/debug/cursor and the menu bar both read this. Reporting "not connected"
    through a working WebRTC session sends every diagnosis down the wrong path."""
    import json as _json

    from phice.paths import Paths
    from phice.runtime import Runtime

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    d = _json.loads(paths.pointer_json.read_text())
    d.update(transport="webrtc", signaling_url="https://example.invalid")
    paths.pointer_json.write_text(_json.dumps(d))

    rt = Runtime(paths, FakeCursor(), 0, 0)
    rt.rtc = RTCTransport(engine=rt.engine, layout_json='{"version":1,"buttons":[]}',
                          theme_css="body{}", ice_servers=())
    status = asyncio.ensure_future(rt._status_loop())
    try:
        phone, _channel = await _connect(rt.rtc)
        for _ in range(30):
            if rt.status.read()["connected"]:
                break
            await asyncio.sleep(0.1)
        assert rt.status.read()["connected"], "an open data channel is a connected phone"
        assert rt._debug_cursor()["phone_url"].endswith("/app")
    finally:
        status.cancel()
        await asyncio.gather(status, return_exceptions=True)
        await phone.close()
        await rt.rtc.close()


async def test_new_code_rotates_even_with_a_phone_already_connected(tmp_path):
    """The panel's "new code" button. Its whole reason to exist is a phone that
    is stuck, so doing nothing while one is attached defeats the point."""
    import json as _json

    from phice.paths import Paths
    from phice.runtime import Runtime

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    d = _json.loads(paths.pointer_json.read_text())
    d.update(transport="webrtc", signaling_url="https://example.invalid")
    paths.pointer_json.write_text(_json.dumps(d))

    codes: list[str] = []
    phones: list[RTCPeerConnection] = []

    class FakeSignaling:
        def __init__(self, *a, **kw):
            pass

        async def fetch_ice_servers(self):
            return None

        async def publish_offer(self, code, offer):
            codes.append(code)
            self._offer = offer

        async def wait_for_answer(self, code, timeout=300.0, interval=1.0):
            if len(codes) > 1:
                await asyncio.sleep(3600)     # only the first code gets a phone
            phone = RTCPeerConnection(configuration=_no_stun())
            phones.append(phone)
            await phone.setRemoteDescription(RTCSessionDescription(**self._offer))
            await phone.setLocalDescription(await phone.createAnswer())
            await gather_complete(phone)
            return {"sdp": phone.localDescription.sdp, "type": phone.localDescription.type}

    import phice.signaling as session_mod
    original, session_mod.SignalingClient = session_mod.SignalingClient, FakeSignaling
    rt = Runtime(paths, FakeCursor(), 0, 0)
    rt._loop = asyncio.get_running_loop()
    rt.rtc_ice_servers = ()
    task = asyncio.ensure_future(signaling.run(rt))
    try:
        for _ in range(100):
            if rt.rtc and rt.rtc.is_open:
                break
            await asyncio.sleep(0.1)
        assert rt.rtc.is_open, "the fake phone never connected"

        rt.new_pair_code()
        for _ in range(100):
            if len(codes) > 1:
                break
            await asyncio.sleep(0.1)
        assert len(codes) > 1, "no fresh offer was published"
        assert codes[1] != codes[0], "the code must actually change"
    finally:
        session_mod.SignalingClient = original
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        for phone in phones:
            await phone.close()
        if rt.rtc:
            await rt.rtc.close()


async def test_the_theme_goes_over_the_reliable_channel(transport):
    """The theme is about 12 KB, which fragments across nine SCTP chunks. On the
    lossy channel losing any one of them discarded the whole message, and the
    page rendered unstyled buttons on a black background with nothing to
    indicate why. Sensor packets stay lossy; anything that must arrive does not."""
    got: dict[str, list] = {"phice": [], "phice-ctl": []}
    phone = RTCPeerConnection(configuration=_no_stun())
    ready = asyncio.get_running_loop().create_future()

    @phone.on("datachannel")
    def on_channel(channel):
        @channel.on("message")
        def on_message(msg):
            got[channel.label].append(json.loads(msg)["t"])
            if {"layout", "theme", "state"} <= set(got["phice-ctl"]) and not ready.done():
                ready.set_result(True)

    offer = await transport.create_offer()
    labels = [ln.split(":")[-1] for ln in offer["sdp"].splitlines() if "webrtc-datachannel" in ln]
    await phone.setRemoteDescription(RTCSessionDescription(**offer))
    await phone.setLocalDescription(await phone.createAnswer())
    await gather_complete(phone)
    await transport.accept_answer({"sdp": phone.localDescription.sdp,
                                   "type": phone.localDescription.type})
    try:
        await asyncio.wait_for(ready, timeout=10)
        assert not got["phice"], f"the lossy channel must carry no control traffic: {got}"
        assert transport.ctl.ordered, "control must be ordered"
        assert transport.ctl.maxRetransmits is None, "control must not give up on a chunk"
        assert transport.channel.maxRetransmits == 0, "sensor packets stay lossy"
    finally:
        await phone.close()
        await transport.close()
        assert labels is not None


async def test_the_active_layout_follows_ui_layout_and_falls_back_safely(tmp_path):
    """A named preset wins; a missing one falls back rather than leaving the
    phone with no buttons, which looks exactly like a broken app."""
    import json as _json

    from phice.paths import Paths
    from phice.runtime import Runtime

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    cfg = paths.pointer_json

    def reload(layout_name):
        d = _json.loads(cfg.read_text())
        d.setdefault("ui", {})["layout"] = layout_name
        cfg.write_text(_json.dumps(d))
        return Runtime(paths, FakeCursor(), 0, 0)

    assert reload("").active_layout_path() == paths.layout_json
    assert reload("one-handed").active_layout_path() == paths.layouts / "one-handed.json"
    assert reload("standard").active_layout_path() == paths.layouts / "standard.json"
    # Named but absent: fall back, do not fail.
    assert reload("does-not-exist").active_layout_path() == paths.layout_json


async def test_switching_grip_reloads_the_layout_the_phone_is_using(tmp_path):
    from phice.paths import Paths
    from phice.runtime import Runtime

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    rt = Runtime(paths, FakeCursor(), 0, 0)
    assert rt.set_layout("one-handed") is True
    rt = Runtime(paths, FakeCursor(), 0, 0)      # as a restart would see it
    power = next(b for b in rt.layout.buttons if b.role == "power")
    pads = [b for b in rt.layout.buttons if b.role != "power"]
    assert all(power.y + power.h <= b.y for b in pads), "power sits above the pads"
    assert max(b.y + b.h for b in pads) >= 96, "the pads reach the bottom"
    assert rt.set_layout("../escape") is False, "a path is not a preset name"
    assert rt.set_layout("nonsense") is False, "an unknown preset is refused"


async def test_an_edited_preset_survives_switching_away_and_back(tmp_path):
    """The presets are separate files and switching only changes a name, so this
    falls out of the design -- but it is the reason the design is that way."""
    import json as _json

    from phice.paths import Paths
    from phice.runtime import Runtime

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    preset = paths.layouts / "one-handed.json"
    edited = _json.loads(preset.read_text())
    edited["buttons"][0]["x"] = 11
    preset.write_text(_json.dumps(edited))

    rt = Runtime(paths, FakeCursor(), 0, 0)
    rt.set_layout("one-handed")
    rt.set_layout("standard")
    rt.set_layout("one-handed")
    assert _json.loads(preset.read_text())["buttons"][0]["x"] == 11


async def test_the_layout_and_theme_are_sent_again_after_a_moment(transport):
    """The Mac sends the instant its own end opens, which can be before the page
    has attached a listener -- and a message dispatched to nobody is gone, with
    no error at either end. One repeat turns a lost theme from a dead status
    light and unstyled buttons into a half-second of them."""
    seen: list[str] = []
    phone = RTCPeerConnection(configuration=_no_stun())

    @phone.on("datachannel")
    def on_channel(channel):
        @channel.on("message")
        def on_message(msg):
            if channel.label == "phice-ctl":
                seen.append(json.loads(msg)["t"])

    offer = await transport.create_offer()
    await phone.setRemoteDescription(RTCSessionDescription(**offer))
    await phone.setLocalDescription(await phone.createAnswer())
    await gather_complete(phone)
    await transport.accept_answer({"sdp": phone.localDescription.sdp,
                                   "type": phone.localDescription.type})
    try:
        for _ in range(40):
            if seen.count("theme") >= 2:
                break
            await asyncio.sleep(0.1)
        assert seen.count("layout") >= 2, f"layout sent once only: {seen}"
        assert seen.count("theme") >= 2, f"theme sent once only: {seen}"
    finally:
        await phone.close()
        await transport.close()
