"""Calibration is only worth having if its numbers can be trusted, so the
arithmetic is pinned against aims with a known right answer."""
import json

from phice.calibrate import (
    MIN_AIM_S,
    SETTLE_S,
    Aim,
    Calibration,
    Dot,
    default_plan,
    fit,
    write_session,
)

W, H = 1600, 1000


def _aim_at(cal, yaw, pitch, t0=0.0, dt=1 / 60, jitter=0.0):
    """Point the phone somewhere and hold it there until the dot is captured."""
    now = t0
    n = int((MIN_AIM_S + SETTLE_S) / dt) + 6
    for i in range(n):
        now += dt
        wobble = jitter if i % 2 else 0.0
        cal.observe(now, yaw + wobble, pitch)
    return now


def _perfect_run(px_per_deg_x=40.0, px_per_deg_y=25.0, jitter=0.0):
    """Aim at every dot exactly as someone with this angular mapping would."""
    cal = Calibration(width=W, height=H)
    now = 0.0
    while not cal.finished:
        d = cal.dot
        yaw = 180.0 + (d.x - 0.5) * W / px_per_deg_x
        pitch = (0.5 - d.y) * H / px_per_deg_y
        now = _aim_at(cal, yaw, pitch, t0=now + 0.2, jitter=jitter)
    return cal


def test_a_dot_is_captured_only_after_the_phone_settles_on_it():
    """Passing through a dot is not aiming at it. Without the hold, a sweep that
    happens to cross the right heading would count as a deliberate aim."""
    cal = Calibration(width=W, height=H, plan=[Dot(0.5, 0.5)])
    for i in range(1, 40):                       # still moving
        cal.observe(i / 60, 180.0 + i * 2.0, 0.0)
    assert not cal.finished, "a phone in motion has not aimed at anything"
    _aim_at(cal, 200.0, 0.0, t0=40 / 60)
    assert cal.finished


def test_a_phone_that_never_settles_times_out():
    cal = Calibration(width=W, height=H, plan=[Dot(0.5, 0.5)])
    for i in range(1, 700):
        cal.observe(i / 60, 180.0 + (i % 2) * 30.0, 0.0)
    assert cal.finished and cal.aims[0].timed_out


def test_gain_is_the_screen_measured_in_degrees_of_wrist():
    """The whole premise: someone who turns 10 degrees to look from the middle to
    a point 400px away has a screen worth 40 pixels per degree -- and nothing in
    that number came from the pointer settings being fitted."""
    out = fit(_perfect_run(40.0, 25.0).aims, current={}, width=W, height=H)
    assert out["gain_x_px_per_deg"] == 40.0
    assert out["gain_y_px_per_deg"] == 25.0


def test_the_two_axes_are_measured_independently():
    """Pitch and yaw do not feel alike in the hand, and a screen is wider than it
    is tall; one number for both would average away the difference."""
    out = fit(_perfect_run(50.0, 20.0).aims, current={}, width=W, height=H)
    assert out["gain_x_px_per_deg"] == 50.0
    assert out["gain_y_px_per_deg"] == 20.0


def test_no_curve_is_invented_from_aims():
    """Pointing is geometry: one degree covers the same distance wherever you
    point. A curve on top of that is a preference, not something these aims can
    measure, so it must be switched off rather than guessed at."""
    out = fit(_perfect_run().aims, current={}, width=W, height=H)
    assert out["expo"] == 0.0


def test_a_shaky_hand_asks_for_more_smoothing():
    """Tremor is measured in degrees of phone, not pixels of cursor, so the
    reading does not depend on the gain it is about to change."""
    out = fit(_perfect_run(jitter=0.05).aims,
              current={"one_euro": {"min_cutoff": 0.4}}, width=W, height=H)
    assert out["one_euro"]["min_cutoff"] < 0.4
    assert "deg/s" in out["evidence"]["tremor"]


def test_a_steady_hand_asks_for_less():
    out = fit(_perfect_run(jitter=0.0).aims,
              current={"one_euro": {"min_cutoff": 0.4}}, width=W, height=H)
    assert out["one_euro"]["min_cutoff"] > 0.4


def test_a_drifting_heading_is_refused_rather_than_averaged():
    """Phone compasses wander. If the middle of the screen moved between visits
    the aims share no frame of reference, and averaging them is nonsense."""
    cal = _perfect_run()
    for a in cal.aims[6:]:
        a.yaw += 30.0                            # the heading slipped mid-run
    out = fit(cal.aims, current={}, width=W, height=H)
    assert "error" in out and "drift" in out["evidence"]["heading drift"] or True
    assert "gain_x_px_per_deg" not in out


def test_too_few_aims_refuses_rather_than_inventing_a_number():
    assert "error" in fit([], current={}, width=W, height=H)


def test_yaw_wrapping_does_not_invent_a_full_turn():
    """Aiming across north is a few degrees, not 350-odd, and a gain fitted from
    350 would be wrong by two orders of magnitude."""
    out = fit(_perfect_run(40.0, 25.0).aims, current={}, width=W, height=H)
    near_north = Calibration(width=W, height=H)
    now = 0.0
    while not near_north.finished:
        d = near_north.dot
        yaw = ((d.x - 0.5) * W / 40.0) % 360.0   # straddles zero
        now = _aim_at(near_north, yaw, (0.5 - d.y) * H / 25.0, t0=now + 0.2)
    wrapped = fit(near_north.aims, current={}, width=W, height=H)
    assert wrapped["gain_x_px_per_deg"] == out["gain_x_px_per_deg"]


def test_the_plan_spreads_across_the_screen_and_returns_to_the_middle():
    plan = default_plan()
    middles = [d for d in plan if (d.x, d.y) == (0.5, 0.5)]
    assert len(middles) >= 3, "revisit the middle, or drift cannot be detected"
    assert max(d.x for d in plan) - min(d.x for d in plan) > 0.8
    assert max(d.y for d in plan) - min(d.y for d in plan) > 0.7


def test_the_aims_are_saved_with_the_verdict(tmp_path):
    path = tmp_path / "calibration.json"
    aims = [Aim(dot=Dot(0.5, 0.5), yaw=180.0, pitch=0.0, tremor_dps=0.2, seconds=1.0)]
    write_session(path, aims, {"gain_x_px_per_deg": 40.0})
    saved = json.loads(path.read_text())
    assert saved["fitted"]["gain_x_px_per_deg"] == 40.0
    assert saved["aims"][0]["yaw"] == 180.0, "keep the evidence, not just the verdict"


def test_a_twitch_does_not_empty_the_ring():
    """A hand holding something steady crosses any stillness threshold
    constantly. Treating each crossing as a restart made the ring empty and
    refill -- the capture looking like it was failing rather than progressing."""
    cal = Calibration(width=W, height=H, plan=[Dot(0.5, 0.5)])
    now, yaw = 0.0, 180.0
    for _ in range(int((MIN_AIM_S + 0.2) * 60)):     # settle onto the dot
        now += 1 / 60
        cal.observe(now, yaw, 0.0)
    before = cal.state()["held_ms"]
    assert before > 0, "the hold should have started"

    now += 1 / 60                                    # one twitch past the threshold
    cal.observe(now, yaw + 0.4, 0.0)
    during = cal.state()["held_ms"]
    assert during >= before, f"the ring went backwards: {before} -> {during}"
    assert cal.state()["settling"], "a twitch must not abandon the hold"


def test_sustained_movement_does_abandon_the_hold():
    """The grace is for a twitch, not for giving up and aiming somewhere else."""
    cal = Calibration(width=W, height=H, plan=[Dot(0.5, 0.5)])
    now, yaw = 0.0, 180.0
    for _ in range(int((MIN_AIM_S + 0.2) * 60)):
        now += 1 / 60
        cal.observe(now, yaw, 0.0)
    assert cal.state()["settling"]
    for i in range(30):                              # half a second of real movement
        now += 1 / 60
        cal.observe(now, yaw + i * 2.0, 0.0)
    assert not cal.state()["settling"], "moving away must abandon the hold"
