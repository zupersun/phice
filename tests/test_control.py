"""The loopback HTTP server behind the panel, the calibration screen and the debug hooks."""
import json
import re
import urllib.error
import urllib.request

import pytest

from phice.control import ControlServer
from phice.paths import DEFAULTS_DIR


@pytest.fixture
def control():
    cursor = {"x": 1, "y": 2}
    calls: list[str] = []
    s = ControlServer(
        0,
        pages={"/panel.css": lambda: b"body{color:red}", "/calibrate.css": lambda: b"i{}"},
        actions={"/debug/cursor": lambda: cursor,
                 "/debug/newcode": lambda: calls.append("newcode"),
                 "/calibrate/start": lambda: {"trials": 3}},
        settings={"/debug/appearance": lambda v: v in ("dark", "light")})
    port = s.start()
    s.calls = calls
    yield s, port
    s.stop()


def get(port, path, method="GET"):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method)
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status, r.headers.get("Content-Type"), r.read()


def status_of(port, path):
    try:
        return get(port, path)[0]
    except urllib.error.HTTPError as e:
        return e.code


def test_it_listens_on_loopback_only(control):
    """Nothing here is for the phone any more: the page is hosted and the pointer
    arrives over a data channel. A server the LAN can reach is a server the LAN
    can poke, for no benefit."""
    s, port = control
    assert s.address == ("127.0.0.1", port)


def test_the_setup_pages_of_the_tls_era_are_gone(control):
    _, port = control
    for path in ("/", "/setup", "/check", "/help", "/pair", "/ca.crt", "/ca.mobileconfig",
                 "/transport", "/nope"):
        assert status_of(port, path) == 404, path


def test_actions_answer_json_and_a_bare_return_means_ok(control):
    s, port = control
    status, ctype, body = get(port, "/debug/cursor")
    assert status == 200 and ctype == "application/json" and json.loads(body) == {"x": 1, "y": 2}
    assert json.loads(get(port, "/debug/newcode", method="POST")[2]) == {"ok": True}
    assert s.calls == ["newcode"]
    assert json.loads(get(port, "/calibrate/start")[2]) == {"trials": 3}


def test_settings_take_a_value_and_report_the_verdict(control):
    _, port = control
    assert json.loads(get(port, "/debug/appearance?v=light")[2]) == {"ok": True, "v": "light"}
    assert status_of(port, "/debug/appearance?v=neon") == 400
    assert status_of(port, "/debug/layout?v=standard") == 404, "an unwired setting is unknown"


def test_pages_are_served_as_css(control):
    _, port = control
    status, ctype, body = get(port, "/panel.css")
    assert status == 200 and ctype.startswith("text/css") and body == b"body{color:red}"
    assert get(port, "/calibrate.css")[2] == b"i{}"


def test_the_two_documents_are_html_and_load_their_own_stylesheets(control):
    _, port = control
    for doc, css in (("/panel", "/panel.css"), ("/calibrate", "/calibrate.css")):
        status, ctype, body = get(port, doc)
        html = body.decode()
        assert status == 200 and "text/html" in ctype
        assert f'href="{css}"' in html
        assert "<style" not in html, f"no design baked into {doc}"


def test_panel_shows_the_pairing_code_and_status_from_one_source(control):
    """Everything the window displays comes from /debug/cursor, so the window and
    the diagnosing command can never disagree."""
    html = get(control[1], "/panel")[2].decode()
    assert "/debug/cursor" in html
    assert "/debug/newcode" in html


def test_panel_theme_control_touches_only_the_data_theme_attribute(control):
    """Appearance is a data-theme attribute on <html>, set from JS exactly like the
    dot classes are for status -- no colour, size, or inline style may live here."""
    html = get(control[1], "/panel")[2].decode()
    assert "style=" not in html
    assert 'setAttribute("data-theme"' in html
    assert '"light"' in html and '"dark"' in html
    assert '"system"' not in html, "the system option was dropped"
    # The properties the script may publish are numbers: the knob's position
    # while a finger is on it, and the code's remaining life. What they look
    # like is the stylesheet's business.
    assert 'setProperty("--knob-drag"' in html
    assert 'setProperty("--code-life"' in html


def test_the_appearance_slider_is_draggable_and_server_backed(control):
    html = get(control[1], "/panel")[2].decode()
    assert "/debug/appearance?v=" in html, "the choice must reach the Mac"
    assert "setPointerCapture" in html, "a drag that leaves the track must keep tracking"
    assert "pointermove" in html and "pointerup" in html


def test_panel_css_has_a_light_base_and_dark_overrides():
    css = (DEFAULTS_DIR / "panel.css").read_text()
    assert "color-scheme: light" in css
    assert "color-scheme: dark" in css
    assert "@media (prefers-color-scheme: dark)" in css
    assert ':root[data-theme="dark"]' in css
    assert ':root[data-theme="light"]' in css


def test_the_panel_offers_calibration_without_needing_a_phone_first(control):
    html = get(control[1], "/panel")[2].decode()
    assert "/calibrate/start" in html
    assert "calibrated" in html, "say whether it has ever been run"


def test_the_panel_publishes_the_codes_life_as_a_number_and_its_state_as_an_attribute(control):
    """Same contract as the scroll strip and the knobs: the script sets a
    number and an attribute, and panel.css decides what they look like. It
    used to show the code alone, which looked identical whether the code was
    live, being renewed, or dead because the letterbox was unreachable."""
    html = get(control[1], "/panel")[2].decode()
    assert 'setProperty("--code-life"' in html
    assert "dataset.pairing" in html
    assert "code_life" in html and "offer_ready" in html and "pairing_error" in html
    assert 'id="code-hint"' in html
    assert "style=" not in html, "no inline style; numbers and attributes only"


def test_panel_css_styles_every_pairing_state():
    css = (DEFAULTS_DIR / "panel.css").read_text()
    assert "--code-life" in css
    # "ready" is the base look the other three states depart from, so it has
    # no rule of its own -- only the states that differ from it need one.
    for state in ("renewing", "error", "connected"):
        assert f'body[data-pairing="{state}"]' in css, state


def test_the_panel_offers_every_shipped_layout_and_nothing_else():
    """The bar's places are the preset names, so adding or renaming a preset
    without the panel knowing would leave a layout nobody can choose."""
    from phice.templates import PANEL_HTML
    presets = {p.stem for p in (DEFAULTS_DIR / "layouts").glob("*.json")}
    bar = re.search(r'id="mode".*?</div>', PANEL_HTML, re.S).group(0)
    assert set(re.findall(r'data-v="([^"]+)"', bar)) == presets
    assert "/debug/block" in PANEL_HTML and "/debug/block-drag" in PANEL_HTML
    assert 'id="grip"' not in PANEL_HTML


def test_the_panel_is_two_screens():
    """Until a phone connects the window shows only the way in: the ticket, the
    steps, and the one permission worth fixing early. The controls arrive once
    a phone has connected."""
    from phice.templates import PANEL_HTML
    a = PANEL_HTML.index('class="screen-pair"')
    b = PANEL_HTML.index('class="screen-live"')
    pair = PANEL_HTML[a:b]
    live = PANEL_HTML[b:PANEL_HTML.index("<script>", b)]
    assert 'id="qr"' in pair and 'id="code"' in pair and 'id="link"' in pair, \
        "ticket: tile, code, address"
    assert 'class="steps"' in pair and pair.count("<li>") == 3
    assert 'id="grant"' in pair, "the one thing worth fixing before a phone arrives"
    assert 'id="mode"' in live and 'id="calibrate"' in live and 'id="newcode"' in live
    assert "Calibrate pointer<" in live, "no ellipsis"
    for gone in ("How to connect", "Pointer feel", "Grip</b>", 'id="url"',
                 'id="copy"', "Enter this on your phone", "It renews itself"):
        assert gone not in PANEL_HTML, gone
    assert "/debug/qr" in PANEL_HTML and "/debug/newcode" in PANEL_HTML


def test_the_panel_sizes_its_window_and_hides_what_it_says_it_hides():
    """The page measures itself and tells the Mac, so the window hugs its
    content in every state. And an element the script marks hidden stays
    hidden whatever display its own rule gives it: the permission card once
    showed for everyone because its flex rule beat the attribute."""
    from phice.templates import PANEL_HTML
    assert "ResizeObserver" in PANEL_HTML and "/debug/panel-size" in PANEL_HTML
    # The content's height, not the document's: a document is never shorter
    # than its window, so measuring it let the window grow but never shrink.
    assert "body.offsetHeight" in PANEL_HTML and "scrollHeight" not in PANEL_HTML
    css = (DEFAULTS_DIR / "panel.css").read_text()
    assert "[hidden] { display: none !important; }" in css
    steps = PANEL_HTML[PANEL_HTML.index('<ol class="steps">'):PANEL_HTML.index("</ol>")]
    assert "iPhone" not in steps and "over the web" not in steps and "so it can tell" not in steps
    assert "cursor on screen and tap the power button" in steps


def test_the_code_life_bar_lands_a_catch_up_at_once():
    """Each second's poll moves the bar a hair, eased. After the window was
    minimised, or when the code is new, the next poll moves it a long way, and
    easing that raced the bar across the card. The script marks such a jump
    and the stylesheet lands it without a transition."""
    from phice.templates import PANEL_HTML
    assert "codeJump" in PANEL_HTML, "the script marks a jump"
    css = (DEFAULTS_DIR / "panel.css").read_text()
    assert "body[data-code-jump] .code-life i { transition: none; }" in css
