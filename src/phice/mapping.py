"""Pure pointer maths: aim in, pixels out.

Extracted from the engine so it can be reasoned about and tested without a
clock, a cursor or a state machine. Nothing here holds state or performs I/O.
"""
from __future__ import annotations

import math

from .orientation import wrap180


def expo_curve(degrees: float, expo: float, ref_deg: float, max_mult: float) -> float:
    """Amplify large offsets from the anchor while leaving small ones alone.

    Spanning a wide screen at a linear gain demands a big arm movement, but
    raising the gain everywhere costs precision. Growing the gain with distance
    from the anchor keeps small corrections one-to-one and makes edge-to-edge
    sweeps cheap. Still a pure function of aim, so absolute mapping keeps its
    no-drift property.
    """
    if expo <= 0.0:
        return degrees
    mult = 1.0 + expo * (abs(degrees) / ref_deg) ** 2
    return degrees * min(mult, max_mult)


def unwrap_yaw(previous_raw: float | None, raw: float, running: float) -> float:
    """Accumulate yaw continuously across the 0/360 seam.

    Yaw arrives wrapped, so 359 -> 1 is a two-degree turn, not a 358-degree one.
    """
    if previous_raw is None:
        return raw
    return running + wrap180(raw - previous_raw)


def absorb_overshoot(target: float, clamped: float, anchor: float,
                     slack: float) -> float:
    """Return the anchor adjusted so overshoot past an edge cannot accumulate.

    Absolute mapping parks the cursor at the edge while you aim beyond it, which
    is wanted. But the discarded excess is otherwise unbounded -- and the expo
    curve multiplies it -- so a wide sweep meant un-aiming almost the whole
    excursion before the cursor would move again. Everything past `slack` is
    absorbed into the anchor, leaving a small deliberate amount of stick.
    """
    excess = target - clamped
    if abs(excess) <= slack:
        return anchor
    return anchor - (excess - math.copysign(slack, excess))


def accel_multiplier(dyaw: float, dpitch: float, dt: float, enabled: bool,
                     threshold_dps: float, k: float, max_mult: float) -> float:
    """Speed-dependent gain for the relative mapping."""
    if not enabled or dt <= 0:
        return 1.0
    speed = math.hypot(dyaw, dpitch) / dt
    return max(1.0, min(max_mult, 1.0 + k * max(0.0, speed - threshold_dps)))
