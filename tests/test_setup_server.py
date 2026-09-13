import json
import urllib.error
import urllib.request

import pytest

from phice.certs import CertPaths, ca_der, ca_mobileconfig, ensure_ca
from phice.pages import check_html, qr_svg, setup_html
from phice.paths import DEFAULTS_DIR
from phice.setup_server import SetupServer


@pytest.fixture
def setup(tmp_path):
    cp = CertPaths.under(tmp_path)
    ensure_ca(cp, "testmac")
    cursor = {"x": 1, "y": 2}
    rotated: list[bool] = []
    s = SetupServer(0, lambda: ca_der(cp), lambda: ("http://10.0.0.5:8080/ca.mobileconfig",
                                                    "https://10.0.0.5:8443/?pair=tok", True,
                                                    "http://testmac.local:8080/ca.mobileconfig",
                                                    "https://testmac.local:8443/?pair=tok"),
                    debug_cursor=lambda: cursor,
                    pair_code=lambda: "ABC123",
                    panel_css=lambda: b"body{color:red}",
                    new_code=lambda: rotated.append(True),
                    ca_mobileconfig=lambda: ca_mobileconfig(cp))
    port = s.start()
    s.rotated = rotated
    yield port
    s.stop()


def get(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as r:
        return r.status, r.headers.get("Content-Type"), r.read()


def test_qr_svg_is_svg():
    svg = qr_svg("https://example.local/?pair=abc")
    assert svg.startswith("<svg") and "path" in svg


def test_ca_download_is_der_with_filename(setup):
    status, ctype, body = get(setup, "/ca.crt")
    assert status == 200 and ctype == "application/x-x509-ca-cert"
    assert body[:1] == b"\x30"


def test_setup_page_has_both_qrs_and_urls(setup):
    status, ctype, body = get(setup, "/setup")
    html = body.decode()
    assert status == 200 and html.count("<svg") == 2  # one QR per step, no ambiguity
    assert "ca.mobileconfig" in html and "pair=tok" in html
    assert "10.0.0.5" in html  # IP form is primary
    assert "testmac.local" in html  # .local demoted to a note


def test_setup_page_hides_ca_card_when_external_certs():
    html = setup_html("http://x/ca.crt", "https://x/?pair=t", show_ca=False)
    assert html.count("<svg") == 1 and "Certificate Trust Settings" not in html


def test_setup_page_omits_alt_note_when_no_address():
    html = setup_html("http://x/ca.crt", "https://x/?pair=t", show_ca=True)
    assert html.count("<svg") == 2 and "Stable alternative" not in html


def test_help_page_and_404(setup):
    assert get(setup, "/help")[0] == 200
    with pytest.raises(urllib.error.HTTPError):
        get(setup, "/nope")


def test_debug_cursor(setup):
    status, _, body = get(setup, "/debug/cursor")
    assert status == 200 and json.loads(body) == {"x": 1, "y": 2}


def test_serves_installable_configuration_profile(setup, tmp_path):
    import plistlib
    status, ctype, body = get(setup, "/ca.mobileconfig")
    assert status == 200
    # iOS only offers the install flow for this exact media type.
    assert ctype == "application/x-apple-aspen-config"
    d = plistlib.loads(body)
    assert d["PayloadType"] == "Configuration"
    payload = d["PayloadContent"][0]
    assert payload["PayloadType"] == "com.apple.security.root"
    assert payload["PayloadContent"]  # the DER certificate is embedded


def test_check_page_probes_the_tls_port_over_plain_http(setup):
    status, ctype, body = get(setup, "/check")
    html = body.decode()
    assert status == 200 and ctype.startswith("text/html")
    # It must probe an asset on the TLS origin: that load only succeeds if the
    # phone already trusts the CA, which is the whole diagnostic.
    assert "https://10.0.0.5:8443/assets/apple-touch-icon.png" in html
    # Both remedies are offered.
    assert "ca.mobileconfig" in html and "Certificate Trust" in html


def test_check_page_links_to_the_pairing_url_when_trusted():
    html = check_html("http://m/ca.mobileconfig", "https://m:8443/?pair=tok")
    assert 'href="https://m:8443/?pair=tok"' in html
    assert "https://m:8443/assets/apple-touch-icon.png" in html


def test_panel_serves_its_stylesheet_separately(setup):
    """The panel's design lives in a file the user owns, exactly like the phone's
    theme. Inlining it into the HTML would make the window unrestylable."""
    status, ctype, body = get(setup, "/panel")
    assert status == 200 and "text/html" in ctype
    html = body.decode()
    assert 'href="/panel.css"' in html
    assert "<style" not in html, "no design baked into the page"
    status, ctype, css = get(setup, "/panel.css")
    assert status == 200 and "text/css" in ctype
    assert css == b"body{color:red}"


def test_panel_shows_the_pairing_code_and_status_from_one_source(setup):
    """Everything the window displays comes from /debug/cursor, so the window and
    the diagnosing command can never disagree."""
    html = get(setup, "/panel")[2].decode()
    assert "/debug/cursor" in html
    assert "/debug/newcode" in html


def test_new_code_button_reaches_the_runtime(setup):
    req = urllib.request.Request(f"http://127.0.0.1:{setup}/debug/newcode", method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        assert r.status == 200


def test_panel_theme_control_touches_only_the_data_theme_attribute(setup):
    """Appearance is a data-theme attribute on <html>, set from JS exactly like the
    dot classes are for status -- no colour, size, or inline style may live here."""
    html = get(setup, "/panel")[2].decode()
    assert "style=" not in html
    assert 'setAttribute("data-theme"' in html
    assert '"light"' in html and '"dark"' in html
    assert '"system"' not in html, "the system option was dropped"
    # The one property the script is allowed to publish is the knob's position
    # while a finger is on it; what that looks like is the stylesheet's business.
    assert 'setProperty("--knob-drag"' in html


def test_the_appearance_slider_is_draggable_and_server_backed(setup):
    """The Mac owns this value because the phone follows it too, so the control
    must read and write the runtime rather than only its own local storage."""
    html = get(setup, "/panel")[2].decode()
    assert "/debug/appearance?v=" in html, "the choice must reach the Mac"
    assert "setPointerCapture" in html, "a drag that leaves the track must keep tracking"
    assert "pointermove" in html and "pointerup" in html


def test_panel_css_has_a_light_base_and_dark_overrides():
    """panel.css must own the palette for every appearance state: a light default,
    dark under prefers-color-scheme, and both explicit data-theme overrides."""
    css = (DEFAULTS_DIR / "panel.css").read_text()
    assert "color-scheme: light" in css
    assert "color-scheme: dark" in css
    assert "@media (prefers-color-scheme: dark)" in css
    assert ':root[data-theme="dark"]' in css
    assert ':root[data-theme="light"]' in css


def test_the_panel_offers_calibration_without_needing_a_phone_first(setup):
    """It is the app's own window, so it is where a feature belongs -- not only
    behind a menu bar item that can be invisible behind the notch. The
    calibration screen pairs on its own, so the button never has to wait."""
    html = get(setup, "/panel")[2].decode()
    assert "/calibrate/start" in html
    assert "calibrated" in html, "say whether it has ever been run"
