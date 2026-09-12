"""The pointer maths, tested without a clock, a cursor or a state machine."""
import pytest

from phice.mapping import absorb_overshoot, accel_multiplier, expo_curve, unwrap_yaw


def test_expo_off_is_the_identity():
    for d in (-40.0, -1.0, 0.0, 0.5, 12.0):
        assert expo_curve(d, 0.0, 18.0, 4.0) == d


def test_expo_leaves_small_offsets_almost_untouched():
    """Precision near the anchor is the whole point of a curve over a bigger gain."""
    assert expo_curve(1.0, 1.2, 18.0, 4.0) == pytest.approx(1.0, abs=0.01)
    assert expo_curve(2.0, 1.2, 18.0, 4.0) == pytest.approx(2.0, abs=0.05)


def test_expo_amplifies_large_offsets_and_respects_the_ceiling():
    assert expo_curve(20.0, 1.2, 18.0, 4.0) > 20.0 * 2
    assert expo_curve(90.0, 1.2, 18.0, 4.0) == pytest.approx(90.0 * 4.0)


def test_expo_is_symmetric():
    assert expo_curve(-15.0, 1.2, 18.0, 4.0) == -expo_curve(15.0, 1.2, 18.0, 4.0)


def test_unwrap_yaw_crosses_the_seam_without_a_jump():
    """359 -> 1 is a two degree turn, not a 358 degree one."""
    assert unwrap_yaw(None, 350.0, 0.0) == 350.0
    assert unwrap_yaw(359.0, 1.0, 359.0) == pytest.approx(361.0)
    assert unwrap_yaw(1.0, 359.0, 361.0) == pytest.approx(359.0)


def test_overshoot_within_slack_leaves_the_anchor_alone():
    assert absorb_overshoot(1450.0, 1439.0, 700.0, 24.0) == 700.0


def test_overshoot_beyond_slack_moves_the_anchor_by_the_excess():
    """Only the amount past the slack is absorbed, so a deliberate stick remains."""
    assert absorb_overshoot(1600.0, 1439.0, 700.0, 24.0) == pytest.approx(700.0 - (161.0 - 24.0))
    assert absorb_overshoot(-200.0, 0.0, 700.0, 24.0) == pytest.approx(700.0 + (200.0 - 24.0))


def test_acceleration_is_disabled_or_needs_real_elapsed_time():
    assert accel_multiplier(50.0, 0.0, 0.016, False, 40.0, 0.01, 3.0) == 1.0
    assert accel_multiplier(50.0, 0.0, 0.0, True, 40.0, 0.01, 3.0) == 1.0


def test_acceleration_only_applies_above_the_threshold_and_is_capped():
    assert accel_multiplier(0.1, 0.0, 0.016, True, 40.0, 0.01, 3.0) == 1.0
    assert accel_multiplier(100.0, 0.0, 0.016, True, 40.0, 0.01, 3.0) == 3.0
