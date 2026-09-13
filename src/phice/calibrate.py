"""Fit the pointer to the person holding the phone, by measuring rather than guessing.

Sensitivity cannot be described in words -- "slightly too fast" is not a number --
so this runs a short target-tracking task and reads the answer off the data.

The central measurement is deliberately simple. Put a target 800 px away, watch
how far the phone actually rotated to reach it, and the gain that would have
landed exactly on it is arithmetic: 800 / 22deg = 36 px/deg. No search, no
scoring function, and no assumption that the person would have behaved the same
way under different settings -- which is the flaw in tuning a closed loop by
replaying it. Repeating that across a range of distances gives the expo curve
too, because expo is precisely how the ratio changes with distance.

Only the filter is fitted by replay, where it is defensible: filtering is
post-processing of an input stream that does not depend on what the cursor did.

This module is pure. Clock, cursor and screen size are injected, so the whole
thing is testable without a phone, a display or a single sleep.
"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path

#: A trial ends when the cursor has sat inside the target for this long. Long
#: enough to exclude a fly-through, short enough not to feel like a chore.
DWELL_S = 0.35
#: Give up on a target rather than trapping someone who cannot reach it.
TRIAL_TIMEOUT_S = 12.0


class Kind(StrEnum):
    STILL = "still"      # hold the phone still: measures tremor, fits the filter
    STEP = "step"        # travel a known distance: measures gain
    SWEEP = "sweep"      # long and fast: measures the top of the expo curve


@dataclass(frozen=True)
class Trial:
    kind: Kind
    #: Target centre in screen fractions, so a plan is resolution independent.
    x: float
    y: float
    radius_px: float
    hold_s: float = 0.0


@dataclass
class TrialResult:
    trial: Trial
    started: float
    ended: float
    #: Where the cursor was when the target appeared, and the target in pixels.
    from_px: tuple[float, float] = (0.0, 0.0)
    to_px: tuple[float, float] = (0.0, 0.0)
    #: Total yaw/pitch the phone actually turned through while reaching it.
    yaw_deg: float = 0.0
    pitch_deg: float = 0.0
    #: Path the cursor travelled. Much longer than the straight line means
    #: hunting -- overshoot, correction, overshoot.
    path_px: float = 0.0
    timed_out: bool = False

    @property
    def distance_px(self) -> float:
        return math.dist(self.from_px, self.to_px)

    @property
    def seconds(self) -> float:
        return self.ended - self.started

    @property
    def overshoot(self) -> float:
        """Path length over straight-line distance. 1.0 is a perfect move."""
        d = self.distance_px
        return self.path_px / d if d > 1.0 else 1.0


def default_plan() -> list[Trial]:
    """Stillness first, then distances from a nudge to most of the screen.

    Directions alternate so a habit of always turning one way cannot bias the
    result, and each distance appears twice: one sample is an anecdote.
    """
    trials = [Trial(Kind.STILL, 0.5, 0.5, 44.0, hold_s=4.0)]
    spread = [0.08, 0.16, 0.28, 0.42]
    for rep in range(2):
        for i, frac in enumerate(spread):
            sign = 1.0 if (i + rep) % 2 == 0 else -1.0
            trials.append(Trial(Kind.STEP, 0.5 + sign * frac, 0.5, 40.0))
            trials.append(Trial(Kind.STEP, 0.5, 0.5 + sign * frac * 0.6, 40.0))
    trials.append(Trial(Kind.STILL, 0.5, 0.5, 44.0, hold_s=4.0))
    for sign in (1.0, -1.0):
        trials.append(Trial(Kind.SWEEP, 0.5 + sign * 0.46, 0.5, 56.0))
        trials.append(Trial(Kind.SWEEP, 0.5 - sign * 0.46, 0.5, 56.0))
    return trials


@dataclass
class Calibration:
    """Runs the plan. Feed it packets and cursor positions; it does the rest."""

    width: int
    height: int
    plan: list[Trial] = field(default_factory=default_plan)
    results: list[TrialResult] = field(default_factory=list)
    index: int = 0
    _current: TrialResult | None = None
    _inside_since: float | None = None
    _last_cursor: tuple[float, float] | None = None
    _last_yaw: float | None = None
    _last_pitch: float | None = None
    finished: bool = False

    # ----- geometry ---------------------------------------------------------

    def target_px(self, trial: Trial) -> tuple[float, float]:
        return trial.x * self.width, trial.y * self.height

    @property
    def trial(self) -> Trial | None:
        return None if self.index >= len(self.plan) else self.plan[self.index]

    @property
    def in_trial(self) -> bool:
        return self._current is not None

    def state(self) -> dict:
        """What the calibration window draws. Fractions, not pixels: the page
        does not need to know the display geometry, only where to put a dot."""
        t = self.trial
        if t is None:
            return {"done": True, "index": self.index, "total": len(self.plan)}
        return {"done": False, "index": self.index, "total": len(self.plan),
                "kind": t.kind.value, "x": t.x, "y": t.y, "radius": t.radius_px,
                "hold": t.hold_s,
                "inside": self._inside_since is not None}

    # ----- the run ----------------------------------------------------------

    def begin(self, now: float, cursor: tuple[float, float]) -> None:
        t = self.trial
        if t is None or self._current is not None:
            return
        self._current = TrialResult(trial=t, started=now, ended=now,
                                    from_px=cursor, to_px=self.target_px(t))
        self._inside_since = None
        self._last_cursor = cursor
        self._last_yaw = self._last_pitch = None

    def observe(self, now: float, cursor: tuple[float, float],
                yaw: float | None, pitch: float | None) -> None:
        """One sample. Accumulates the phone's rotation and the cursor's path."""
        cur = self._current
        if cur is None or self.finished:
            return
        if self._last_cursor is not None:
            cur.path_px += math.dist(cursor, self._last_cursor)
        self._last_cursor = cursor
        if yaw is not None:
            if self._last_yaw is not None:
                cur.yaw_deg += abs(_wrapped(yaw - self._last_yaw))
            self._last_yaw = yaw
        if pitch is not None:
            if self._last_pitch is not None:
                cur.pitch_deg += abs(pitch - self._last_pitch)
            self._last_pitch = pitch

        t = cur.trial
        if t.kind is Kind.STILL:
            if now - cur.started >= t.hold_s:
                self._finish(now)
            return
        if math.dist(cursor, cur.to_px) <= t.radius_px:
            if self._inside_since is None:
                self._inside_since = now
            elif now - self._inside_since >= DWELL_S:
                self._finish(now)
        else:
            self._inside_since = None
        if now - cur.started > TRIAL_TIMEOUT_S:
            cur.timed_out = True
            self._finish(now)

    def _finish(self, now: float) -> None:
        cur = self._current
        if cur is None:
            return
        cur.ended = now
        self.results.append(cur)
        self._current = None
        self.index += 1
        self.finished = self.index >= len(self.plan)


def _wrapped(delta: float) -> float:
    """Shortest way round the circle, so 359 -> 1 is two degrees, not 358."""
    return (delta + 180.0) % 360.0 - 180.0


# ----- reading the answer off the data --------------------------------------

def fit(results: list[TrialResult], current: dict) -> dict:
    """Turn finished trials into pointer.json settings.

    Returns the settings that changed, plus the evidence behind each one, so a
    number can always be traced back to the trials that produced it.
    """
    steps = [r for r in results
             if r.trial.kind in (Kind.STEP, Kind.SWEEP) and not r.timed_out
             and r.distance_px > 20.0 and r.yaw_deg + r.pitch_deg > 1.0]
    out: dict = {"samples": len(steps), "evidence": {}}
    _fit_stillness(results, current, out)
    if len(steps) < 4:
        if not out["evidence"]:
            out["error"] = "too few usable trials to fit anything"
        return out

    horizontal = [r for r in steps if abs(r.to_px[0] - r.from_px[0]) > abs(r.to_px[1] - r.from_px[1])]
    vertical = [r for r in steps if r not in horizontal]

    gain_x = _gain_from(horizontal, axis=0)
    gain_y = _gain_from(vertical, axis=1)
    if gain_x:
        out["gain_x_px_per_deg"] = round(gain_x, 1)
        out["evidence"]["gain_x_px_per_deg"] = f"{len(horizontal)} sideways trials"
    if gain_y:
        out["gain_y_px_per_deg"] = round(gain_y, 1)
        out["evidence"]["gain_y_px_per_deg"] = f"{len(vertical)} vertical trials"

    expo = _expo_from(steps)
    if expo is not None:
        out["expo"] = round(expo, 2)
        out["evidence"]["expo"] = ("ratio of degrees to pixels across "
                                   f"{len(steps)} distances")

    hunting = [r.overshoot for r in steps if r.overshoot > 0]
    if hunting:
        mean_overshoot = sum(hunting) / len(hunting)
        out["evidence"]["overshoot"] = f"{mean_overshoot:.2f}x the straight line"
        # Hunting round the target is the signature of too little smoothing at
        # low speed; a clean approach means the filter can be lightened.
        cutoff = float(current.get("one_euro", {}).get("min_cutoff", 0.4))
        if mean_overshoot > 1.9:
            out.setdefault("one_euro", {})["min_cutoff"] = round(max(0.15, cutoff * 0.6), 2)
        elif mean_overshoot < 1.25:
            out.setdefault("one_euro", {})["min_cutoff"] = round(min(2.0, cutoff * 1.4), 2)

    return out


def _fit_stillness(results: list[TrialResult], current: dict, out: dict) -> None:
    """A cursor that wanders while the phone is held still is unfiltered tremor."""
    still = [r for r in results if r.trial.kind is Kind.STILL and r.seconds > 0.5]
    if not still:
        return
    drift = sum(r.path_px for r in still) / len(still)
    per_second = drift / (sum(r.seconds for r in still) / len(still))
    out["evidence"]["drift"] = f"{per_second:.1f} px/s while holding still"
    if per_second > 12.0:
        cutoff = float(current.get("one_euro", {}).get("min_cutoff", 0.4))
        out.setdefault("one_euro", {})["min_cutoff"] = round(max(0.1, cutoff * 0.5), 2)


def _gain_from(trials: list[TrialResult], axis: int) -> float | None:
    """Pixels per degree, as the median of what each trial actually demanded.

    Median rather than mean: one trial where the phone was fumbled would drag an
    average a long way, and there are only a dozen of them.
    """
    ratios = []
    for r in trials:
        turned = r.yaw_deg if axis == 0 else r.pitch_deg
        if turned < 1.0:
            continue
        ratios.append(abs(r.to_px[axis] - r.from_px[axis]) / turned)
    if not ratios:
        return None
    ratios.sort()
    mid = len(ratios) // 2
    return ratios[mid] if len(ratios) % 2 else (ratios[mid - 1] + ratios[mid]) / 2


def _expo_from(trials: list[TrialResult]) -> float | None:
    """How much faster the far targets need to be than the near ones.

    With no expo, pixels per degree is constant. If long moves consistently
    demand fewer degrees per pixel than short ones, that ratio is the curve.
    """
    near = [r for r in trials if r.distance_px < 300.0]
    far = [r for r in trials if r.distance_px >= 600.0]
    if len(near) < 2 or len(far) < 2:
        return None
    def ppd(rs: list[TrialResult]) -> float:
        vals = [r.distance_px / max(1.0, r.yaw_deg + r.pitch_deg) for r in rs]
        return sum(vals) / len(vals)
    near_ppd, far_ppd = ppd(near), ppd(far)
    if near_ppd <= 0:
        return None
    return max(0.0, min(4.0, far_ppd / near_ppd))


def write_session(path: Path, results: list[TrialResult], fitted: dict) -> None:
    """Keep the trials, not just the conclusion: a number nobody can check is
    a number nobody can argue with."""
    payload = {
        "fitted": fitted,
        "trials": [
            {"kind": r.trial.kind.value, "distance_px": round(r.distance_px, 1),
             "yaw_deg": round(r.yaw_deg, 2), "pitch_deg": round(r.pitch_deg, 2),
             "seconds": round(r.seconds, 2), "path_px": round(r.path_px, 1),
             "overshoot": round(r.overshoot, 2), "timed_out": r.timed_out}
            for r in results
        ],
    }
    path.write_text(json.dumps(payload, indent=2) + "\n")


class Runner:
    """Owns a calibration run: the trials, the samples, and writing the result.

    Kept out of the runtime because none of it is about serving a phone, and
    because a run is entirely described by three things it borrows -- where the
    config lives, what the cursor is doing, and the engine's raw look direction.
    """

    def __init__(self, paths, backend, engine, show):
        self._paths = paths
        self._backend = backend
        self._engine = engine
        self._show = show                    # open the calibration window
        self.current: Calibration | None = None

    def start(self) -> dict:
        displays = self._backend.displays()
        rect = displays[0] if displays else None
        width, height = (int(rect.w), int(rect.h)) if rect else (1440, 900)
        self.current = Calibration(width=width, height=height)
        self._engine.on_look = self._sample
        self._show()
        return {"trials": len(self.current.plan), "width": width, "height": height}

    def _sample(self, now: float, yaw: float, pitch: float) -> None:
        cal = self.current
        if cal is None or cal.finished:
            return
        pos = self._backend.get_position()
        if cal.trial is not None and not cal.in_trial:
            cal.begin(now, pos)
        cal.observe(now, pos, yaw, pitch)
        if cal.finished:
            self._engine.on_look = None      # stop sampling the moment it ends

    def cancel(self) -> None:
        self._engine.on_look = None
        self.current = None

    def _config(self) -> dict:
        return json.loads(self._paths.pointer_json.read_text())

    def state(self) -> dict:
        cal = self.current
        if cal is None:
            return {"running": False}
        state = dict(cal.state(), running=True)
        if cal.finished:
            state["fitted"] = fit(cal.results, self._config())
        return state

    def apply(self) -> dict:
        """Write the fitted settings, and the trials that produced them."""
        cal = self.current
        if cal is None or not cal.finished:
            return {"ok": False, "error": "calibration has not finished"}
        data = self._config()
        fitted = fit(cal.results, data)
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
        write_session(self._paths.sessions / "calibration.json", cal.results, fitted)
        return {"ok": True, "fitted": fitted}
