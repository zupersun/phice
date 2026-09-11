"""Procedurally drawn default assets.

Menu-bar icons are template images: black pixels with an alpha mask, which
macOS recolours for light and dark menu bars. Generating them avoids shipping
binary blobs, and the user can overwrite the PNGs with their own at any time.
"""
from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

SIZE = 36  # 18 pt at 2x


def _chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def _png_bytes(w: int, h: int, colour_type: int, raw: bytes) -> bytes:
    return (b"\x89PNG\r\n\x1a\n"
            + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, colour_type, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(raw, 9))
            + _chunk(b"IEND", b""))


def _png(pixels: list[list[int]]) -> bytes:
    """Encode an 8-bit grayscale+alpha template image (colour is always black)."""
    h, w = len(pixels), len(pixels[0])
    raw = b"".join(b"\x00" + bytes(b for a in row for b in (0, a)) for row in pixels)
    return _png_bytes(w, h, 4, raw)


def _png_rgba(pixels: list[list[tuple[int, int, int, int]]]) -> bytes:
    h, w = len(pixels), len(pixels[0])
    raw = b"".join(b"\x00" + bytes(c for px in row for c in px) for row in pixels)
    return _png_bytes(w, h, 6, raw)


def touch_icon(size: int = 180) -> bytes:
    """Home Screen icon: iOS requires PNG here, so draw one rather than ship SVG."""
    bg, accent = (11, 15, 20, 255), (62, 166, 255, 255)
    cx, cy = size / 2, size / 2
    rx, ry = size * 0.17, size * 0.29
    stroke = size * 0.039
    wheel_w, wheel_top, wheel_h = size * 0.045, size * 0.32, size * 0.145
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            fx, fy = (x - cx + 0.5) / rx, (y - cy + 0.5) / ry
            d = math.hypot(fx, fy)
            on_body = abs(d - 1.0) * min(rx, ry) <= stroke / 2
            in_wheel = (abs(x - cx + 0.5) <= wheel_w / 2
                        and wheel_top <= y <= wheel_top + wheel_h)
            row.append(accent if (on_body or in_wheel) else bg)
        rows.append(row)
    return _png_rgba(rows)


def _blank() -> list[list[int]]:
    return [[0] * SIZE for _ in range(SIZE)]


def _disc(px, cx, cy, r, alpha=255):
    for y in range(SIZE):
        for x in range(SIZE):
            if math.hypot(x - cx + 0.5, y - cy + 0.5) <= r:
                px[y][x] = max(px[y][x], alpha)


def _rect(px, x0, y0, x1, y1, alpha=255):
    for y in range(max(0, y0), min(SIZE, y1)):
        for x in range(max(0, x0), min(SIZE, x1)):
            px[y][x] = max(px[y][x], alpha)


def _mouse_body(px, alpha=255):
    """A rounded mouse outline: the shared silhouette of every state icon."""
    cx, top, bottom, rx = SIZE / 2, 6, 30, 9
    for y in range(SIZE):
        for x in range(SIZE):
            fx = (x - cx + 0.5) / rx
            if top <= y <= bottom:
                cy = (top + bottom) / 2
                fy = (y - cy + 0.5) / ((bottom - top) / 2)
                d = math.hypot(fx, fy)
                if 0.82 <= d <= 1.0:
                    px[y][x] = max(px[y][x], alpha)


def icon_disconnected() -> bytes:
    px = _blank()
    _mouse_body(px, 150)
    return _png(px)


def icon_off() -> bytes:
    px = _blank()
    _mouse_body(px)
    _rect(px, 17, 10, 19, 17)  # the scroll wheel
    return _png(px)


def icon_on() -> bytes:
    px = _blank()
    _mouse_body(px)
    _disc(px, SIZE / 2, 13.5, 4.2)
    return _png(px)


def icon_warn() -> bytes:
    px = _blank()
    _mouse_body(px, 140)
    _rect(px, 17, 11, 19, 20)  # exclamation stem
    _rect(px, 17, 22, 19, 25)  # exclamation dot
    return _png(px)


LOGO_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 24" fill="none">
  <rect x="1" y="3" width="12" height="18" rx="6" stroke="currentColor" stroke-width="1.6"/>
  <rect x="6.2" y="7" width="1.6" height="5" rx="0.8" fill="currentColor"/>
  <text x="19" y="17" font-family="-apple-system, system-ui, sans-serif" font-size="12"
        font-weight="600" letter-spacing="1.5" fill="currentColor">PHICE</text>
</svg>
"""

def write_defaults(assets: Path) -> None:
    """Create any default asset that is missing. Never overwrites the user's files."""
    (assets / "menubar").mkdir(parents=True, exist_ok=True)
    for name, data in (("warn", icon_warn()), ("disconnected", icon_disconnected()),
                       ("off", icon_off()), ("on", icon_on())):
        p = assets / "menubar" / f"{name}.png"
        if not p.exists():
            p.write_bytes(data)
    logo = assets / "logo.svg"
    if not logo.exists():
        logo.write_text(LOGO_SVG)
    touch = assets / "apple-touch-icon.png"
    if not touch.exists():
        touch.write_bytes(touch_icon())
    (assets / "icons").mkdir(exist_ok=True)
