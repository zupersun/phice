import math
import random

import pytest

from phice.orientation import pointing_vector, rotation_matrix, wrap180, yaw_pitch


def test_identity_points_along_y():
    assert pointing_vector(0, 0, 0) == pytest.approx((0.0, 1.0, 0.0))
    assert yaw_pitch(0, 0, 0) == pytest.approx((0.0, 0.0))


def test_turning_right_is_positive_yaw():
    # W3C alpha grows counter-clockwise seen from above, so turning right is alpha = 270.
    yaw, pitch = yaw_pitch(270, 0, 0)
    assert yaw == pytest.approx(90.0)
    assert pitch == pytest.approx(0.0)
    yaw, _ = yaw_pitch(90, 0, 0)
    assert yaw == pytest.approx(-90.0)


def test_raising_top_edge_is_positive_pitch():
    _, pitch = yaw_pitch(0, 30, 0)
    assert pitch == pytest.approx(30.0)
    _, pitch = yaw_pitch(0, -20, 0)
    assert pitch == pytest.approx(-20.0)


def test_roll_never_changes_aim():
    rng = random.Random(42)
    for _ in range(200):
        alpha = rng.uniform(0, 360)
        beta = rng.uniform(-80, 80)
        ref = yaw_pitch(alpha, beta, 0.0)
        for _ in range(10):
            gamma = rng.uniform(-90, 90)
            assert yaw_pitch(alpha, beta, gamma) == pytest.approx(ref, abs=1e-9)


def test_rotation_matrix_is_orthonormal():
    r = rotation_matrix(33, -47, 12)
    for i in range(3):
        for j in range(3):
            dot = sum(r[k][i] * r[k][j] for k in range(3))
            assert dot == pytest.approx(1.0 if i == j else 0.0, abs=1e-12)


def test_wrap180():
    assert wrap180(190) == pytest.approx(-170)
    assert wrap180(-190) == pytest.approx(170)
    assert wrap180(179) == pytest.approx(179)
    assert wrap180(360) == pytest.approx(0)
    assert wrap180(-180) == pytest.approx(-180)
    assert math.isclose(wrap180(0), 0)
