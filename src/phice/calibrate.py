"""Fit the pointer by watching where someone naturally points, with no cursor.

The obvious design is to show a target, let the person drive the cursor onto it,
and measure how far they turned the phone. It does not work, and not by a little:
it is circular. At gain G, covering D pixels *requires* turning D/G degrees, so
the person turns until the cursor arrives and the measurement comes back as
D / (D/G) = G -- the setting it already had, dressed up as a discovery. What it
really records is correction behaviour, and nudging a cursor into a circle is not
how anyone points at a thing.

So there is no cursor here. Dots appear, the person points the phone at each one
as they would point at anything, and holds still. That measures the real
quantity: how many pixels of screen one degree of wrist rotation covers, at the
distance they actually sit and in the grip they actually use. Nothing in the loop
depends on the settings being fitted, so the answer cannot echo them back.

Tremor is measured the same way -- in degrees per second of the phone, not pixels
of cursor travel -- so it too is independent of the gain.

This module is pure. Clock and screen size are injected; the tests need no phone,
no display and no sleeping.
"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from pathlib import Path

#: The phone counts as aimed once it has been this still for this long. Capturing
#: on stillness rather than a button press keeps the aim honest: reaching for a
#: button moves the phone, which is precisely the thing being measured.
STILL_DPS = 6.0
SETTLE_S = 0.45
#: Do not capture before this: the phone is still travelling to the dot, and a
#: momentary pause on the way is not an aim.
MIN_AIM_S = 0.6
#: Give up on a dot rather than trapping someone who cannot hold still enough.
DOT_TIMEOUT_S = 8.0


@dataclass(frozen=True)
class Dot:
    """Somewhere to point, in screen fractions so a plan survives any display."""

    x: float
    y: float
    #: Shown to the person. The middle is visited repeatedly, and saying so stops
    #: it looking as though nothing is happening.
    note: str = ""


@dataclass
class Aim:
    """Where the phone was pointing when it settled on a dot."""

    dot: Dot
    yaw: float
    pitch: float
    #: Angular travel per second while holding: the person's tremor in degrees,
    #: which is the same number whatever the pointer gain happens to be.
    tremor_dps: float
    seconds: float
    timed_out: bool = False


def default_plan() -> list[Dot]:
    """Middle, then out to the edges and corners, returning to the middle.

    Every measurement is a difference between two aims, so the spread of dots
    matters more than their number. Revisiting the middle catches heading drift:
    phone compasses wander, and a run where the middle moved is one to discard
    rather than average.
    """
    plan = [Dot(0.5, 0.5, "Start here")]
    plan += [Dot(0.08, 0.5), Dot(0.92, 0.5)]
    plan.append(Dot(0.5, 0.5, "Back to the middle"))
    plan += [Dot(0.5, 0.08), Dot(0.5, 0.92)]
    plan += [Dot(0.1, 0.12), Dot(0.9, 0.12), Dot(0.9, 0.88), Dot(0.1, 0.88)]
    plan.append(Dot(0.5, 0.5, "Last one"))
    return plan


@dataclass
class Calibration:
    """Runs the plan. Feed it the phone\'s look direction; it does the rest."""

    width: int
    height: int
    plan: list[Dot] = field(default_factory=default_plan)
    aims: list[Aim] = field(default_factory=list)
    index: int = 0
    finished: bool = False
    _started: float | None = None
    _still_since: float | None = None
    _last: tuple[float, float] | None = None
    _last_t: float | None = None
    _travel: float = 0.0
    _held: float = 0.0

    @property
    def dot(self) -> Dot | None:
        return None if self.index >= len(self.plan) else self.plan[self.index]

    def dot_px(self, dot: Dot) -> tuple[float, float]:
        return dot.x * self.width, dot.y * self.height

    def state(self) -> dict:
        d = self.dot
        if d is None:
            return {"done": True, "index": self.index, "total": len(self.plan)}
        return {"done": False, "index": self.index, "total": len(self.plan),
                "x": d.x, "y": d.y, "note": d.note,
                "settling": self._still_since is not None,
                # Milliseconds, not a fraction: the page animates the ring itself
                # at the display's refresh rate. A fraction sampled by its poll
                # gave eight frames a second.
                "settle_ms": int(SETTLE_S * 1000),
                "held_ms": int(max(0.0, self._held) * 1000)}

    def observe(self, now: float, yaw: float, pitch: float) -> None:
        """One sample of where the phone is pointing."""
        if self.finished or self.dot is None:
            return
        if self._started is None:
            self._started, self._last, self._last_t = now, (yaw, pitch), now
            self._travel = 0.0
            return
        moved = math.hypot(_wrapped(yaw - self._last[0]), pitch - self._last[1])
        dt = max(1e-3, now - (self._last_t or now))
        self._last, self._last_t = (yaw, pitch), now
        self._travel += moved

        if moved / dt < STILL_DPS and now - self._started >= MIN_AIM_S:
            if self._still_since is None:
                self._still_since, self._held, self._travel = now, 0.0, 0.0
            else:
                self._held = now - self._still_since
            if self._held >= SETTLE_S:
                self._capture(now, yaw, pitch)
                return
        else:
            self._still_since, self._held = None, 0.0
        if now - self._started > DOT_TIMEOUT_S:
            self._capture(now, yaw, pitch, timed_out=True)

    def _capture(self, now: float, yaw: float, pitch: float, timed_out: bool = False) -> None:
        self.aims.append(Aim(dot=self.dot, yaw=yaw, pitch=pitch,
                             tremor_dps=self._travel / max(1e-3, self._held),
                             seconds=now - (self._started or now), timed_out=timed_out))
        self.index += 1
        self._started = self._still_since = self._last_t = None
        self._held = self._travel = 0.0
        self.finished = self.index >= len(self.plan)


def _wrapped(delta: float) -> float:
    """Shortest way round the circle, so 359 -> 1 is two degrees, not 358."""
    return (delta + 180.0) % 360.0 - 180.0


# ----- reading the answer off the aims ---------------------------------------

#: Below these a pair says nothing useful: a handful of pixels over a fraction of
#: a degree is noise with a large number attached to it.
MIN_TRAVEL_PX = 120.0
MIN_TURN_DEG = 2.0
#: Two aims at the same dot should agree. If the middle moved by more than this
#: between visits, the heading drifted and the aims share no frame of reference.
MAX_DRIFT_DEG = 12.0


def fit(results: list[Aim], current: dict, width: int, height: int) -> dict:
    """Turn captured aims into pointer.json settings, with the evidence."""
    good = [a for a in results if not a.timed_out]
    out: dict = {"samples": len(good), "evidence": {}}
    if len(good) < 4:
        out["error"] = "too few aims to fit anything"
        return out

    drift = _centre_drift(good)
    if drift is not None:
        out["evidence"]["heading drift"] = f"{drift:.1f} deg between visits to the middle"
        if drift > MAX_DRIFT_DEG:
            out["error"] = ("the phone heading drifted during the run, so the aims do "
                            "not share a frame of reference; please run it again")
            return out

    gain_x, used_x = _gain(good, axis=0, size=width)
    gain_y, used_y = _gain(good, axis=1, size=height)
    if gain_x:
        out["gain_x_px_per_deg"] = round(gain_x, 1)
        out["evidence"]["gain_x_px_per_deg"] = f"{used_x} pairs of aims"
    if gain_y:
        out["gain_y_px_per_deg"] = round(gain_y, 1)
        out["evidence"]["gain_y_px_per_deg"] = f"{used_y} pairs of aims"

    # Pointing is geometry: a degree covers the same distance wherever you point.
    # Any curve on top of that is a preference about feel, which these aims
    # cannot measure, so it is switched off rather than invented.
    out["expo"] = 0.0
    out["evidence"]["expo"] = "off: pointing is linear, so the mapping should be too"

    tremor = min(a.tremor_dps for a in good)
    out["evidence"]["tremor"] = f"{tremor:.2f} deg/s at the steadiest aim"
    if gain_x:
        px = tremor * gain_x
        out["evidence"]["tremor"] += f" ({px:.0f} px/s at this gain)"
        cutoff = float(current.get("one_euro", {}).get("min_cutoff", 0.4))
        if px > 25.0:
            out.setdefault("one_euro", {})["min_cutoff"] = round(max(0.2, cutoff * 0.6), 2)
        elif px < 6.0:
            out.setdefault("one_euro", {})["min_cutoff"] = round(min(1.2, cutoff * 1.5), 2)
    return out


def _centre_drift(aims: list[Aim]) -> float | None:
    """How far the middle of the screen moved between visits to it."""
    yaws = [a.yaw for a in aims if a.dot.x == 0.5 and a.dot.y == 0.5]
    if len(yaws) < 2:
        return None
    return max(abs(_wrapped(b - a)) for a in yaws for b in yaws)


def _gain(aims: list[Aim], axis: int, size: int) -> tuple[float | None, int]:
    """Pixels per degree, as the median over every usable pair of aims.

    Pairs, not absolute positions: only differences mean anything, since where
    the phone\'s zero happens to sit says nothing about anybody\'s screen.
    """
    ratios = []
    for i, a in enumerate(aims):
        for b in aims[i + 1:]:
            px = abs((b.dot.x - a.dot.x) * size) if axis == 0 \
                else abs((b.dot.y - a.dot.y) * size)
            turned = abs(_wrapped(b.yaw - a.yaw)) if axis == 0 else abs(b.pitch - a.pitch)
            if px < MIN_TRAVEL_PX or turned < MIN_TURN_DEG:
                continue
            ratios.append(px / turned)
    if len(ratios) < 3:
        return None, len(ratios)
    ratios.sort()
    mid = len(ratios) // 2
    value = ratios[mid] if len(ratios) % 2 else (ratios[mid - 1] + ratios[mid]) / 2
    return value, len(ratios)


def write_session(path: Path, results: list[Aim], fitted: dict) -> None:
    """Keep the aims, not just the conclusion: a number nobody can check is a
    number nobody can argue with, and a corrected fit should never oblige anyone
    to do the whole thing over."""
    path.write_text(json.dumps({
        "fitted": fitted,
        "aims": [{"x": a.dot.x, "y": a.dot.y, "yaw": round(a.yaw, 2),
                  "pitch": round(a.pitch, 2), "tremor_dps": round(a.tremor_dps, 3),
                  "seconds": round(a.seconds, 2), "timed_out": a.timed_out}
                 for a in results],
    }, indent=2) + "\n")


class Runner:
    """Owns a run: the dots, the aims, and writing the result.

    Kept out of the runtime because none of it is about serving a phone. It needs
    the engine only to borrow the look direction, and to make sure the pointer is
    not driving the cursor while someone is trying to point naturally.
    """

    def __init__(self, paths, backend, engine, show):
        self._paths = paths
        self._backend = backend
        self._engine = engine
        self._show = show
        self.current: Calibration | None = None
        self.started = False
        self._was_enabled = True

    def start(self) -> dict:
        """Prepare a run and show the window. Sampling waits for begin()."""
        displays = self._backend.displays()
        rect = displays[0] if displays else None
        width, height = (int(rect.w), int(rect.h)) if rect else (1440, 900)
        self.current = Calibration(width=width, height=height)
        self.started = False
        self._show()
        return {"dots": len(self.current.plan), "width": width, "height": height}

    def begin(self) -> dict:
        if self.current is None:
            return {"ok": False, "error": "nothing prepared"}
        self.started = True
        # The cursor must not move. Someone correcting a cursor is not pointing,
        # and a measurement taken through that loop returns the gain it started
        # with rather than anything about the person.
        self._was_enabled = self._engine.enabled
        self._engine.set_enabled(False)
        self._engine.on_packet = self._sample
        return {"ok": True}

    def _sample(self, now: float, yaw: float, pitch: float) -> None:
        cal = self.current
        if cal is None or not self.started or cal.finished:
            return
        cal.observe(now, yaw, pitch)
        if cal.finished:
            self._release()

    def _release(self) -> None:
        self._engine.on_packet = None
        self._engine.set_enabled(self._was_enabled)

    def cancel(self) -> None:
        self._release()
        self.current = None
        self.started = False

    def _config(self) -> dict:
        return json.loads(self._paths.pointer_json.read_text())

    def state(self) -> dict:
        cal = self.current
        if cal is None:
            return {"running": False}
        state = dict(cal.state(), running=True, started=self.started)
        if cal.finished:
            state["fitted"] = fit(cal.aims, self._config(), cal.width, cal.height)
        return state

    def apply(self) -> dict:
        """Write the fitted settings, and the aims that produced them."""
        cal = self.current
        if cal is None or not cal.finished:
            return {"ok": False, "error": "calibration has not finished"}
        data = self._config()
        fitted = fit(cal.aims, data, cal.width, cal.height)
        if "error" in fitted:
            return {"ok": False, **fitted}
        for key, value in fitted.items():
            if key in ("samples", "evidence"):
                continue
            if key == "one_euro":
                data.setdefault("one_euro", {}).update(value)
            else:
                data[key] = value
        self._paths.pointer_json.write_text(json.dumps(data, indent=2) + "\n")
        write_session(self._paths.sessions / "calibration.json", cal.aims, fitted)
        return {"ok": True, "fitted": fitted}
