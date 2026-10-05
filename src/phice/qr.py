"""The QR the panel shows: the pairing link, encoded small, drawn in the panel's language.

The payload is the link in upper case with the code as its path. That keeps the
symbol in QR's alphanumeric mode, a version smaller than the same link in byte
mode, and the site forwards that path to the page with the code filled in. The
drawing is rounded lines: every run of dark modules a bar with rounded ends, a
lone module a rounded square, the three finders rounded rings, in whatever
colour the stylesheet gives it.
"""
from __future__ import annotations

import segno


def pairing_url(signaling_url: str, code: str) -> str:
    """What the panel shows and copies: the short link, with the code if there is one."""
    base = signaling_url.rstrip("/")
    return f"{base}/{code}" if code else f"{base}/app"


def qr_payload(signaling_url: str, code: str) -> str:
    return pairing_url(signaling_url, code).upper()


def _in_finder(n: int, r: int, c: int) -> bool:
    return (r < 7 and c < 7) or (r < 7 and c >= n - 7) or (r >= n - 7 and c < 7)


def qr_svg(payload: str, radius: float = 0.32) -> str:
    """An SVG of the symbol, one module per unit, coloured by currentColor."""
    rows = segno.make(payload, error="m").matrix_iter(scale=1, border=0)
    m = [[bool(v) for v in row] for row in rows]
    n = len(m)

    def dark(r: int, c: int) -> bool:
        return 0 <= r < n and 0 <= c < n and m[r][c] and not _in_finder(n, r, c)

    parts = []
    for r in range(n):
        for c in range(n):
            if not dark(r, c):
                continue
            up, dn, lf, rt = dark(r - 1, c), dark(r + 1, c), dark(r, c - 1), dark(r, c + 1)
            # A square whose convex corners are rounded: runs of modules merge
            # into rounded bars, and a lone module is a rounded square.
            tl, tr = (not up and not lf), (not up and not rt)
            br, bl = (not dn and not rt), (not dn and not lf)
            k = radius
            arc = f"a{k},{k} 0 0 1 "
            d = f"M{c + (k if tl else 0)},{r}"
            d += f"H{c + 1 - (k if tr else 0)}" + (arc + f"{k},{k}" if tr else "")
            d += f"V{r + 1 - (k if br else 0)}" + (arc + f"-{k},{k}" if br else "")
            d += f"H{c + (k if bl else 0)}" + (arc + f"-{k},-{k}" if bl else "")
            d += f"V{r + (k if tl else 0)}" + (arc + f"{k},-{k}" if tl else "")
            parts.append(d + "z")
    finders = ""
    for r0, c0 in ((0, 0), (0, n - 7), (n - 7, 0)):
        finders += (f'<rect x="{c0 + 0.5}" y="{r0 + 0.5}" width="6" height="6" rx="1.9" fill="none" '
                    f'stroke="currentColor" stroke-width="1"/>'
                    f'<rect x="{c0 + 2}" y="{r0 + 2}" width="3" height="3" rx="0.9"/>')
    return (f'<svg viewBox="0 0 {n} {n}" fill="currentColor"><path d="{"".join(parts)}" '
            f'stroke="currentColor" stroke-width="0.04" stroke-linejoin="round"/>{finders}</svg>')


class PairingQR:
    """Drawn once per code: the panel asks when the code changes, not every poll."""

    def __init__(self) -> None:
        self._code = ""
        self._svg = ""

    def describe(self, signaling_url: str, code: str) -> dict:
        url = pairing_url(signaling_url, code)
        if not code:
            return {"code": "", "url": url, "svg": ""}
        if code != self._code:
            self._code, self._svg = code, qr_svg(qr_payload(signaling_url, code))
        return {"code": code, "url": url, "svg": self._svg}
