"""Calibration is only worth having if its numbers can be trusted, so the
arithmetic is pinned against trials with a known right answer."""
import math

from phice.calibrate import (
    DWELL_S,
    Calibration,
    Kind,
    Trial,
    TrialResult,
    default_plan,
    fit,
)


def _run(cal: Calibration, trial_px, turn_deg, *, axis=0, steps=20, t0=0.0, dt=1 / 60):
    """Drive one trial to completion, turning `turn_deg` in total on the way."""
    now = t0
    start = (cal.width / 2, cal.height / 2)
    cal.begin(now, start)
    for i in range(steps):
        now += dt
        frac = i / (steps - 1)
        pos = (start[0] + (trial_px[0] - start[0]) * frac,
               start[1] + (trial_px[1] - start[1]) * frac)
        yaw = turn_deg * frac if axis == 0 else 0.0
        pitch = turn_deg * frac if axis == 1 else 0.0
        cal.observe(now, pos, yaw, pitch)
    for _ in range(int(DWELL_S / dt) + 2):      # sit on the target so it registers
        now += dt
        cal.observe(now, trial_px, turn_deg if axis == 0 else 0.0,
                    turn_deg if axis == 1 else 0.0)
    return now


def test_a_trial_ends_only_after_dwelling_on_the_target():
    """Flying through a target is not reaching it: without a dwell, a wild swing
    that happens to cross the dot would count as a clean move."""
    cal = Calibration(width=1600, height=1000, plan=[Trial(Kind.STEP, 0.75, 0.5, 40.0)])
    cal.begin(0.0, (800.0, 500.0))
    cal.observe(0.1, (1200.0, 500.0), 10.0, 0.0)      # dead centre of the target
    assert not cal.finished, "arriving is not the same as staying"
    cal.observe(0.1 + DWELL_S + 0.01, (1200.0, 500.0), 10.0, 0.0)
    assert cal.finished


def test_a_target_that_cannot_be_reached_times_out():
    """Otherwise a mis-set gain traps the user in a trial they cannot finish."""
    cal = Calibration(width=1600, height=1000, plan=[Trial(Kind.STEP, 0.9, 0.5, 20.0)])
    cal.begin(0.0, (800.0, 500.0))
    for i in range(1, 900):
        cal.observe(i * 0.02, (810.0, 500.0), 0.1 * i, 0.0)
    assert cal.finished and cal.results[0].timed_out


def test_gain_is_the_pixels_the_target_demanded_per_degree_actually_turned():
    """The whole premise: 800px reached with 20 degrees of turn means 40 px/deg,
    and that is arithmetic rather than a search."""
    cal = Calibration(width=1600, height=1000,
                      plan=[Trial(Kind.STEP, 0.75, 0.5, 40.0)] * 6)
    now = 0.0
    for _ in range(6):
        now = _run(cal, (1200.0, 500.0), 10.0, t0=now) + 0.1
    out = fit(cal.results, current={})
    # 400px of travel for 10 degrees of yaw.
    assert out["gain_x_px_per_deg"] == 40.0


def test_horizontal_and_vertical_are_fitted_separately():
    """Holding a phone makes pitch and yaw feel different; one number for both
    would average away exactly the difference worth capturing.

    Both come from every trial that moved far enough on that axis. Sorting
    trials into horizontal and vertical instead threw most of them away: a
    vertical target sits at centre-x while the cursor starts at the last
    target, off to one side, so the displacement read as horizontal."""
    plan = [Trial(Kind.STEP, 0.75, 0.5, 40.0), Trial(Kind.STEP, 0.5, 0.75, 40.0)] * 3
    cal = Calibration(width=1600, height=1000, plan=plan)
    now = 0.0
    for _ in range(3):
        now = _run(cal, (1200.0, 500.0), 10.0, axis=0, t0=now) + 0.1   # 40 px/deg
        now = _run(cal, (800.0, 750.0), 25.0, axis=1, t0=now) + 0.1    # 10 px/deg
    out = fit(cal.results, current={})
    assert out["gain_x_px_per_deg"] == 40.0
    assert out["gain_y_px_per_deg"] == 10.0


def test_hunting_round_the_target_asks_for_more_smoothing():
    """A path far longer than the straight line is overshoot and correction,
    which is what too little smoothing at low speed looks like."""
    cal = Calibration(width=1600, height=1000, plan=[Trial(Kind.STEP, 0.75, 0.5, 40.0)] * 5)
    now = 0.0
    for _ in range(5):
        start = (800.0, 500.0)
        cal.begin(now, start)
        # Overshoot well past the target, come back, overshoot again. The phone
        # turns with the cursor, or there is no rotation to fit a gain from.
        for pos in [(1500.0, 500.0), (900.0, 500.0), (1400.0, 500.0), (1200.0, 500.0)]:
            now += 0.1
            cal.observe(now, pos, (pos[0] - 800.0) / 40.0, 0.0)
        for _ in range(30):
            now += 1 / 60
            cal.observe(now, (1200.0, 500.0), 10.0, 0.0)
        now += 0.1
    out = fit(cal.results, current={"one_euro": {"min_cutoff": 0.4}})
    assert out["one_euro"]["min_cutoff"] < 0.4, "hunting means smooth it more"


def _hold_still(px_per_frame, hold_s=2.0):
    cal = Calibration(width=1600, height=1000,
                      plan=[Trial(Kind.STILL, 0.5, 0.5, 44.0, hold_s=hold_s)])
    cal.begin(0.0, (800.0, 500.0))
    for i in range(1, int(hold_s * 60) + 8):
        cal.observe(i / 60, (800.0 + (i % 2) * px_per_frame, 500.0), 0.0, 0.0)
    return cal


def test_a_shaky_hand_while_holding_still_asks_for_more_smoothing():
    cal = _hold_still(0.3)                       # ~18 px/s: a real hand
    out = fit(cal.results, current={"one_euro": {"min_cutoff": 0.4}})
    assert float(out["evidence"]["drift"].split()[0]) > 12
    assert out["one_euro"]["min_cutoff"] < 0.4


def test_a_phone_being_carried_is_not_evidence_about_smoothing():
    """The first trial starts while the person is still settling into position.
    380px of "drift" in four seconds is someone moving, and acting on it drove
    smoothing to the floor and made the pointer laggy."""
    cal = _hold_still(30.0)                      # ~1800 px/s: nobody's tremor
    out = fit(cal.results, current={"one_euro": {"min_cutoff": 0.4}})
    assert "ignored" in out["evidence"]["drift"]
    assert "one_euro" not in out, "an implausible reading must change nothing"


def test_one_run_may_only_nudge_the_smoothing():
    """Jumping to the floor on a single noisy sample is how a two-minute task
    produced a pointer that felt worse than the guess it replaced."""
    cal = _hold_still(0.3)
    out = fit(cal.results, current={"one_euro": {"min_cutoff": 0.4}})
    assert out["one_euro"]["min_cutoff"] >= 0.2


def test_too_few_trials_refuses_rather_than_inventing_a_number():
    out = fit([], current={})
    assert "error" in out and "gain_x_px_per_deg" not in out


def test_yaw_wrapping_does_not_invent_a_full_turn():
    """Crossing north is two degrees, not 358, and a gain fitted from 358 would
    be wrong by two orders of magnitude."""
    cal = Calibration(width=1600, height=1000, plan=[Trial(Kind.STEP, 0.75, 0.5, 40.0)])
    cal.begin(0.0, (800.0, 500.0))
    cal.observe(0.1, (900.0, 500.0), 359.0, 0.0)
    cal.observe(0.2, (1000.0, 500.0), 1.0, 0.0)
    assert cal._current.yaw_deg < 5.0


def test_the_default_plan_covers_stillness_near_and_far():
    kinds = {t.kind for t in default_plan()}
    assert kinds == {Kind.STILL, Kind.STEP, Kind.SWEEP}
    distances = {round(abs(t.x - 0.5), 3) for t in default_plan() if t.kind is Kind.STEP}
    assert len(distances) >= 4, "one distance cannot separate gain from expo"


def test_results_are_written_with_the_trials_behind_them(tmp_path):
    from phice.calibrate import write_session
    r = TrialResult(trial=Trial(Kind.STEP, 0.7, 0.5, 40.0), started=0.0, ended=1.0,
                    from_px=(0.0, 0.0), to_px=(400.0, 0.0), yaw_deg=10.0, path_px=420.0)
    path = tmp_path / "calibration.json"
    write_session(path, [r], {"gain_x_px_per_deg": 40.0})
    saved = __import__("json").loads(path.read_text())
    assert saved["fitted"]["gain_x_px_per_deg"] == 40.0
    assert saved["trials"][0]["yaw_deg"] == 10.0, "keep the evidence, not just the verdict"
    # The endpoints must survive, or a corrected fit cannot be re-run offline.
    assert saved["trials"][0]["from_px"] == [0.0, 0.0]
    assert saved["trials"][0]["to_px"] == [400.0, 0.0]
    assert math.isclose(saved["trials"][0]["overshoot"], 1.05, abs_tol=0.01)
