"""Contract between the Vercel-hosted phone page and the Mac.

The page is plain files with no build step and no JS test runner, so these check
the few invariants that have actually broken in the field.
"""
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
    # data-state is written only from the Mac's status message.
    writes = [ln.strip() for ln in js.splitlines() if "dataset.state" in ln]
    assert len(writes) == 1 and "msg.phase" in writes[0], writes


def test_every_screen_the_script_selects_is_stylable(html, js):
    """A screen name with no rule renders as nothing at all -- which is exactly
    how the Start button disappeared."""
    named = {ln.split('setScreen("')[1].split('"')[0]
             for ln in js.splitlines() if 'setScreen("' in ln}
    for name in named - {"live"}:   # "live" deliberately shows no overlay
        assert f'body[data-screen="{name}"]' in html, f"no rule for screen {name!r}"


def test_the_mac_and_the_hosted_page_serve_the_same_client():
    """There used to be two copies. They drifted: the Mac's lost light and dark,
    haptics and the screen split, because every phone change had to be made
    twice and one copy quietly missed out."""
    packaged = Path(__file__).resolve().parents[1] / "src" / "phice" / "web"
    assert packaged.is_symlink(), "the packaged client must not be a second copy"
    assert packaged.resolve() == WEB.resolve()


def test_the_client_chooses_its_transport_rather_than_assuming_one(js):
    """Served by the Mac it opens a socket; served by Vercel it pairs by code.
    Only this seam may differ -- the wire protocol either side of it is one."""
    assert 'fetch("/transport"' in js, "ask, do not guess which transport this is"
    assert "new WebSocket(" in js and "RTCPeerConnection(" in js
    # Nothing outside the seam may know which transport it got.
    outside = [ln for ln in js.splitlines()
               if "readyState" in ln and "get open()" not in ln]
    assert not outside, f"transport details leaked out of the seam: {outside}"
