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
