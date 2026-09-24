"""The runtime glue: what it reports, what it forwards to the phone, how it stops."""
import asyncio
import json
import time

import pytest

from phice.cursor_backend import FakeCursor
from phice.paths import Paths
from phice.runtime import Runtime, Status


class _FakeRTC:
    def __init__(self):
        self.pushes = 0
        self.closed = False
        self.is_open = True
        self.client_name = "iPhone"

    def notify_state(self):
        self.pushes += 1

    async def close(self):
        self.closed = True


def _bare_runtime() -> Runtime:
    rt = Runtime.__new__(Runtime)
    rt._loop = None
    rt.status = Status()
    rt.rtc = None
    return rt


def test_menu_bar_calls_after_the_loop_dies_are_discarded():
    """The menu bar outlives the runtime thread, so it can still call in after
    the loop has closed. That used to raise on every tick and leave the
    coroutine un-awaited."""
    rt = _bare_runtime()

    async def coro():
        return None

    closed = asyncio.new_event_loop()
    closed.close()
    for loop in (closed, None):
        rt._loop = loop
        assert Runtime._dispatch(rt, coro()) is False  # discarded, not raised


@pytest.mark.asyncio
async def test_accessibility_is_reported_and_pushed_to_the_phone_on_change():
    """The status is the one source: the panel reads it, and the phone is told
    the moment it changes rather than at the next half-second poll."""
    rt = _bare_runtime()
    rt._loop = asyncio.get_running_loop()
    rt.rtc = _FakeRTC()
    rt.set_accessibility(True)
    await asyncio.sleep(0.05)       # dispatched across the loop, not called inline
    assert rt.status.read()["accessibility"] is True
    assert rt.rtc.pushes == 1
    rt.set_accessibility(True)      # unchanged: nothing to tell the phone
    await asyncio.sleep(0.05)
    assert rt.rtc.pushes == 1
    rt.set_accessibility(False)
    await asyncio.sleep(0.05)
    assert rt.rtc.pushes == 2


@pytest.mark.asyncio
async def test_stop_ends_the_session(tmp_path):
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    rt = Runtime(paths, FakeCursor(), 0)
    rt._loop = asyncio.get_running_loop()
    rt.rtc = _FakeRTC()
    rt.stop()
    await asyncio.sleep(0.05)
    assert rt.rtc.closed


def test_a_recording_captures_frames_verbatim_and_stops_cleanly(tmp_path):
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    rt = Runtime(paths, FakeCursor(), 0)
    path = rt.set_recording(True)
    assert path is not None and path.parent == paths.sessions
    rt.record('{"t":"s","seq":1}')
    rt.record('{"t":"s","seq":2}')
    assert rt.set_recording(False) is None
    rt.record('{"t":"s","seq":3}')        # after stopping: dropped, not raised
    lines = [json.loads(ln) for ln in path.read_text().splitlines()]
    assert [ln["raw"] for ln in lines] == ['{"t":"s","seq":1}', '{"t":"s","seq":2}']
    assert lines[0]["rx"] <= lines[1]["rx"]


def test_the_debug_snapshot_names_the_letterbox_and_the_phone_page(tmp_path):
    """tools/fake_phone.py pairs through whatever letterbox the Mac is using, so
    the Mac has to say which one that is."""
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    rt = Runtime(paths, FakeCursor(), 0)
    d = rt._debug_cursor()
    assert d["signaling_url"] == "https://phice.vercel.app"
    assert d["phone_url"] == "https://phice.vercel.app/app"
    assert d["offer_ready"] is False, "nothing published yet"
    assert d["code_expires_in"] == 0 and d["code_life"] == 0.0
    assert d["pairing_error"] == ""
    for gone in ("transport", "cert_mode", "phone_caps", "tls_url"):
        assert gone not in d


@pytest.mark.asyncio
async def test_offer_ready_means_the_letterbox_holds_the_current_offer(tmp_path):
    """After a disconnect the old offer lingers in the letterbox until the next
    one is gathered and published. A phone -- or the fake one -- that answers
    the stale offer fails ICE, so the Mac says when the current one is up."""
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    rt = Runtime(paths, FakeCursor(), 0)
    assert rt._debug_cursor()["offer_ready"] is False
    rt.pairing.waiter = asyncio.get_running_loop().create_future()
    assert rt._debug_cursor()["offer_ready"] is True
    rt.pairing.waiter.cancel()
    rt.pairing.waiter = None
    assert rt._debug_cursor()["offer_ready"] is False


async def test_code_life_never_shows_more_than_a_full_bar(tmp_path):
    """A clock that steps backwards must not draw more than a full bar."""
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    rt = Runtime(paths, FakeCursor(), 0)
    rt.pairing.waiter = asyncio.get_running_loop().create_future()
    rt.pairing.ttl = 7.0
    rt.pairing.published_at = time.time() + 5.0
    assert rt._debug_cursor()["code_life"] == 1.0
    rt.pairing.waiter.cancel()
    rt.pairing.waiter = None
