import json
import urllib.error
import urllib.request

import pytest

from phice.certs import CertPaths, ca_der, ca_mobileconfig, ensure_ca
from phice.setup_server import SetupServer, check_html, qr_svg, setup_html


@pytest.fixture
def setup(tmp_path):
    cp = CertPaths.under(tmp_path)
    ensure_ca(cp, "testmac")
    cursor = {"x": 1, "y": 2}
    s = SetupServer(0, lambda: ca_der(cp), lambda: ("http://10.0.0.5:8080/ca.mobileconfig",
                                                    "https://10.0.0.5:8443/?pair=tok", True,
                                                    "http://testmac.local:8080/ca.mobileconfig",
                                                    "https://testmac.local:8443/?pair=tok"),
                    debug_cursor=lambda: cursor,
                    ca_mobileconfig=lambda: ca_mobileconfig(cp))
    port = s.start()
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
