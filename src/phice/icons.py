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


def _blank() -> list[list[int]]:
    return [[0] * SIZE for _ in range(SIZE)]


# The mark, on the hundred-square box it is drawn in: a domed body with the parting
# cut out of it. assets/logo.svg is exactly this path and the panel draws the same
# one inline, so the window and the asset can never drift apart. The hips are three
# cubics rather than an arc because the corners are continuous curvature -- the
# softness the pad itself is drawn with.
LOGO_PATH = (
    "M 21 41.48 A 29 32.48 0 0 1 79 41.48 L 79 62 C 79 70.35 79 74.526 77.579 79.02 "
    "C 75.793 83.927 71.927 87.793 67.02 89.579 C 62.526 91 58.35 91 50 91 L 50 91 "
    "C 41.65 91 37.474 91 32.98 89.579 C 28.073 87.793 24.207 83.927 22.421 79.02 "
    "C 21 74.526 21 70.35 21 62 Z "
    "M 47.5 22.5 A 2.5 2.5 0 0 1 52.5 22.5 L 52.5 47.5 A 2.5 2.5 0 0 1 47.5 47.5 Z"
)
LOGO_SVG = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">\n'
            f'  <path fill="currentColor" fill-rule="evenodd" d="{LOGO_PATH}"/>\n'
            f'</svg>\n')

# The same shape as numbers, because the menu bar takes an image and not an SVG:
# the body 58 wide and 82 tall, its dome 0.56 of the width deep, its hips as round
# as they go without the two meeting, and the parting 5 wide, starting 11 below the
# top and running 30 down.
_BODY_W, _BODY_H = 58.0, 82.0
_DOME, _HIP = 0.56, 1 / (2 * 1.52866483)
_SEAM_W, _SEAM_Y, _SEAM_H = 5.0, 11.0, 30.0
_STROKE = 2.6                        # the hollow mark's weight, in icon pixels


def _mark(alpha: int = 255, hollow: bool = False) -> list[list[int]]:
    """The logo rasterised into the menu bar's square, antialiased by supersampling.

    Circular hips rather than the continuous ones the SVG draws: at eighteen points
    the difference is well under a pixel, and the arithmetic stays readable.
    """
    bh = SIZE - 4.0
    bw = bh * _BODY_W / _BODY_H
    cx, ty = SIZE / 2, 2.0
    sw = bw * _SEAM_W / _BODY_W
    sy, sh = ty + bh * _SEAM_Y / _BODY_H, bh * _SEAM_H / _BODY_H

    def body(x: float, y: float, inset: float = 0.0) -> bool:
        w, h, top = bw - 2 * inset, bh - 2 * inset, ty + inset
        rx, dy, rb = w / 2, w * _DOME, w * _HIP
        if y < top + dy:
            return ((x - cx) / rx) ** 2 + ((y - top - dy) / dy) ** 2 <= 1.0
        if abs(x - cx) > rx or y > top + h:
            return False
        if y > top + h - rb:
            if x < cx - rx + rb:
                return math.hypot(x - (cx - rx + rb), y - (top + h - rb)) <= rb
            if x > cx + rx - rb:
                return math.hypot(x - (cx + rx - rb), y - (top + h - rb)) <= rb
        return True

    def seam(x: float, y: float) -> bool:
        r = sw / 2
        if abs(x - cx) > r:
            return False
        if sy + r <= y <= sy + sh - r:
            return True
        return (math.hypot(x - cx, y - (sy + r)) <= r
                or math.hypot(x - cx, y - (sy + sh - r)) <= r)

    px, n = _blank(), 4
    for row in range(SIZE):
        for col in range(SIZE):
            hits = 0
            for i in range(n):
                for j in range(n):
                    x, y = col + (j + 0.5) / n, row + (i + 0.5) / n
                    if not body(x, y):
                        continue
                    if hollow:
                        # Hollow, the parting is drawn rather than cut: a ring on
                        # its own is a pill, and the parting is what makes it a
                        # mouse at eighteen points.
                        if body(x, y, _STROKE) and not seam(x, y):
                            continue
                    elif seam(x, y):
                        continue
                    hits += 1
            if hits:
                px[row][col] = round(alpha * hits / (n * n))
    return px


# Four weights of the one mark. Filled means a phone is on the other end; hollow
# means none is. How bright says how much it wants you.
def icon_on() -> bytes:
    """Connected, and the pointer is driving the cursor."""
    return _png(_mark(255))


def icon_off() -> bytes:
    """Connected, pointer not armed: the same mark, carrying less."""
    return _png(_mark(165))


def icon_disconnected() -> bytes:
    """No phone. Hollow, so filled and empty tell apart at a glance."""
    return _png(_mark(150, hollow=True))


def icon_warn() -> bytes:
    """Something needs you: the permission, or the pairing service. Hollow, but lit."""
    return _png(_mark(255, hollow=True))


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
    (assets / "icons").mkdir(exist_ok=True)
