"""Orientation math: W3C DeviceOrientation Euler angles -> pointing direction.

The phone's "top" axis is device +Y. Rotating it into the room frame gives the
aim vector; yaw/pitch of that vector drive the cursor. Because the W3C order is
Z (alpha) · X' (beta) · Y'' (gamma) and gamma rotates about the very axis we
project, roll (gamma) cancels out exactly.
"""
from __future__ import annotations

import math

Vec3 = tuple[float, float, float]
Mat3 = tuple[Vec3, Vec3, Vec3]


def wrap180(deg: float) -> float:
    """Wrap an angle (difference) into [-180, 180)."""
    return (deg + 180.0) % 360.0 - 180.0


def _mul(m: Mat3, n: Mat3) -> Mat3:
    return tuple(  # type: ignore[return-value]
        tuple(sum(m[i][k] * n[k][j] for k in range(3)) for j in range(3)) for i in range(3)
    )


def rotation_matrix(alpha: float, beta: float, gamma: float) -> Mat3:
    """R = Rz(alpha) · Rx(beta) · Ry(gamma), angles in degrees (W3C convention)."""
    a, b, g = (math.radians(v) for v in (alpha, beta, gamma))
    ca, sa = math.cos(a), math.sin(a)
    cb, sb = math.cos(b), math.sin(b)
    cg, sg = math.cos(g), math.sin(g)
    rz: Mat3 = ((ca, -sa, 0.0), (sa, ca, 0.0), (0.0, 0.0, 1.0))
    rx: Mat3 = ((1.0, 0.0, 0.0), (0.0, cb, -sb), (0.0, sb, cb))
    ry: Mat3 = ((cg, 0.0, sg), (0.0, 1.0, 0.0), (-sg, 0.0, cg))
    return _mul(_mul(rz, rx), ry)


def pointing_vector(alpha: float, beta: float, gamma: float) -> Vec3:
    """Room-frame direction of the phone's top edge (R · (0, 1, 0))."""
    r = rotation_matrix(alpha, beta, gamma)
    return (r[0][1], r[1][1], r[2][1])


def yaw_pitch(alpha: float, beta: float, gamma: float) -> tuple[float, float]:
    """Yaw (deg, positive = turning right) and pitch (deg, positive = top edge up)."""
    x, y, z = pointing_vector(alpha, beta, gamma)
    yaw = math.degrees(math.atan2(x, y))
    pitch = math.degrees(math.asin(max(-1.0, min(1.0, z))))
    return yaw, pitch
