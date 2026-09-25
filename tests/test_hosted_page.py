"""Contract between the Vercel-hosted phone page and the Mac.

The page is plain files with no build step and no JS test runner, so these check
the few invariants that have actually broken in the field.
"""
import re
from pathlib import Path

import pytest

WEB = Path(__file__).resolve().parents[1] / "web" / "app"


@pytest.fixture
def html() -> str:
    return (WEB / "index.html").read_text()


@pytest.fixture
def js() -> str:
    return (WEB / "app.js").read_text()


def test_the_pushed_theme_cannot_delete_the_pages_own_chrome(html, js):
    """The Mac replaces #theme wholesale. When that was the only stylesheet it
    also deleted the rule that shows the Start button, so motion access could
    never be granted and the phone streamed nothing at all."""
    assert '<style id="theme">' in html
    assert '<style id="shell">' in html
    assert html.index('id="theme"') < html.index('id="shell"'), \
        "the shell must come last so it wins a specificity tie"
    assert 'getElementById("theme")' in js
    assert 'getElementById("shell")' not in js, "the shell is never written to"


def test_the_pairing_flow_and_the_engine_phase_use_separate_attributes(html, js):
    """One shared attribute meant the Mac's first status message ("phase: off")
    wiped out whichever pairing screen was showing."""
    assert 'data-screen="pair"' in html
    assert "dataset.screen" in js
    # data-state is written only from the Mac's status message. Assert that of
    # every assignment, rather than counting mentions: reading it to compare is
    # fine, and a line count made an ordinary guard look like a violation.
    writes = [ln.strip() for ln in js.splitlines()
              if "dataset.state =" in ln or "dataset.state=" in ln]
    assert writes, "nothing sets data-state at all"
    assert all("msg.phase" in ln for ln in writes), writes


def test_every_screen_the_script_selects_is_stylable(html, js):
    """A screen name with no rule renders as nothing at all -- which is exactly
    how the Start button disappeared."""
    named = {ln.split('setScreen("')[1].split('"')[0]
             for ln in js.splitlines() if 'setScreen("' in ln}
    for name in named - {"live"}:   # "live" deliberately shows no overlay
        assert f'body[data-screen="{name}"]' in html, f"no rule for screen {name!r}"


def test_the_mac_reads_the_client_version_from_the_deployed_file():
    """The Mac no longer serves the page, but it still needs to know which
    client it expects so a phone running a cached copy can be named as such.
    Reading the deployed file through the symlink keeps that in step with no
    second copy of the number anywhere."""
    packaged = Path(__file__).resolve().parents[1] / "src" / "phice" / "web"
    assert packaged.is_symlink(), "the packaged client must not be a second copy"
    assert packaged.resolve() == WEB.resolve()


def test_the_client_has_exactly_one_way_in(js):
    """It used to open a WebSocket when served by the Mac and pair by code when
    hosted. Nothing serves it from the Mac any more, and a second way in is a
    second thing to keep in step -- they drifted last time."""
    assert "RTCPeerConnection(" in js
    assert "WebSocket" not in js
    assert "/transport" not in js
    assert "welcome" not in js and "phice.token" not in js, "no device tokens: the code pairs"


def test_an_already_open_channel_still_starts_the_session(js):
    """A data channel can be open by the time the datachannel event arrives, and
    then "open" never fires. Waiting for it left the page on "Connecting..."
    forever, depending purely on timing."""
    assert 'if (channel.readyState === "open") ready();' in js
    assert 'else channel.addEventListener("open", ready);' in js


def test_the_message_listener_is_attached_before_anything_can_arrive(js):
    """The Mac sends the layout and theme the instant its end opens. A message
    dispatched before a listener exists is dropped, and the pad renders empty --
    a black screen with no explanation."""
    body = js[js.index("function wireChannel("):]
    body = body[:body.index("\n  }")]
    assert body.index('addEventListener("message"') < body.index("const ready"), \
        "the message listener must come first"


def test_the_phone_rides_through_a_renewal(js):
    """The Mac republishes under the same code every five minutes and needs a
    few seconds to gather the new offer. Eight seconds of retries could miss
    that window, and the message then sent people to the Mac for a fresh code
    that never changes."""
    m = re.search(r"attempt < (\d+) && !offer", js)
    assert m, "the retry loop moved"
    loop = js[js.index("let offer = null"):js.index("if (!offer)")]
    d = re.search(r"setTimeout\(r, (\d+)\)\)", loop)
    assert d, "the retry delay moved"
    assert int(m.group(1)) * int(d.group(1)) >= 20_000, "retry for at least twenty seconds"
    assert "fresh one" not in js
    assert "renews the code by itself" in js
    v = re.search(r'CLIENT_VERSION = "(\d+)"', js)
    assert v, "the client version constant moved"
    assert int(v.group(1)) >= 11, "the client changed, so its version must"
