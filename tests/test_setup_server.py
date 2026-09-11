import json
import urllib.error
import urllib.request

import pytest

from phice.certs import CertPaths, ca_der, ensure_ca
from phice.setup_server import SetupServer, qr_svg, setup_html


@pytest.fixture
def setup(tmp_path):
    cp = CertPaths.under(tmp_path)
    ensure_ca(cp, "testmac")
    cursor = {"x": 1, "y": 2}
    s = SetupServer(0, lambda: ca_der(cp), lambda: ("http://testmac.local:8080/ca.crt",
                                                    "https://testmac.local:8443/?pair=tok", True),
                    debug_cursor=lambda: cursor)
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
    assert status == 200 and html.count("<svg") == 2
    assert "ca.crt" in html and "pair=tok" in html


def test_setup_page_hides_ca_card_when_external_certs():
    html = setup_html("http://x/ca.crt", "https://x/?pair=t", show_ca=False)
    assert html.count("<svg") == 1 and "Certificate Trust Settings" not in html


def test_help_page_and_404(setup):
    assert get(setup, "/help")[0] == 200
    with pytest.raises(urllib.error.HTTPError):
        get(setup, "/nope")


def test_debug_cursor(setup):
    status, _, body = get(setup, "/debug/cursor")
    assert status == 200 and json.loads(body) == {"x": 1, "y": 2}
