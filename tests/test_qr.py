"""The QR the panel shows: the pairing link, encoded small, drawn in the panel's language."""
import segno

from phice.qr import pairing_url, qr_payload, qr_svg


def test_the_link_carries_the_code_as_its_path():
    assert pairing_url("https://phice.vercel.app", "34XEJA") == "https://phice.vercel.app/34XEJA"
    assert pairing_url("https://phice.vercel.app", "") == "https://phice.vercel.app/app"


def test_the_payload_fits_alphanumeric_mode_so_the_code_stays_small():
    """Upper case and no query string: alphanumeric mode is a version smaller
    than byte mode for the same link, and a 25-module code scans more easily."""
    p = qr_payload("https://phice.vercel.app", "34XEJA")
    assert p == "HTTPS://PHICE.VERCEL.APP/34XEJA"
    q = segno.make(p, error="m")
    assert q.mode == "alphanumeric" and q.version <= 2


def test_the_svg_is_rounded_lines_in_the_panels_ink():
    svg = qr_svg("HTTPS://PHICE.VERCEL.APP/34XEJA")
    assert svg.startswith("<svg") and 'fill="currentColor"' in svg, "the stylesheet colours it"
    assert svg.count('rx="1.9"') == 3, "three rounded finder rings"
    assert "<circle" not in svg, "lines, not dots"
    assert "a0.32,0.32" in svg, "rounded corners on the runs"
