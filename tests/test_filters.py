import math

import pytest

from phice.filters import OneEuroFilter


def test_first_sample_passes_through():
    f = OneEuroFilter()
    assert f.filter(5.0, 0.0) == 5.0


def test_constant_input_stays_constant():
    f = OneEuroFilter()
    out = [f.filter(3.0, i * 0.016) for i in range(50)]
    assert all(v == pytest.approx(3.0) for v in out)


def test_noise_is_reduced_at_low_speed():
    f = OneEuroFilter(min_cutoff=1.0, beta=0.0)
    raw, out = [], []
    for i in range(400):
        x = 0.5 * math.sin(i * 0.9)  # high-frequency jitter around 0
        raw.append(x)
        out.append(f.filter(x, i * 0.016))
    rms = lambda xs: math.sqrt(sum(v * v for v in xs[100:]) / len(xs[100:]))  # noqa: E731
    assert rms(out) < 0.3 * rms(raw)


def test_fast_motion_has_low_lag():
    slow = OneEuroFilter(min_cutoff=1.0, beta=0.0)
    fast = OneEuroFilter(min_cutoff=1.0, beta=0.5)
    lag_slow = lag_fast = 0.0
    for i in range(200):
        t = i * 0.016
        x = 500.0 * t  # 500 units/s ramp
        lag_slow = x - slow.filter(x, t)
        lag_fast = x - fast.filter(x, t)
    assert lag_fast < lag_slow * 0.2


def test_reset_forgets_history():
    f = OneEuroFilter()
    f.filter(0.0, 0.0)
    f.filter(100.0, 0.016)
    f.reset()
    assert f.filter(7.0, 1.0) == 7.0


def test_rejects_bad_params():
    with pytest.raises(ValueError):
        OneEuroFilter(min_cutoff=0)
