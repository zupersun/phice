"""Signal filters used by the pointer engine."""
from __future__ import annotations

import math


class OneEuroFilter:
    """One Euro filter (Casiez, Roussel, Vogel 2012).

    Smooths jitter at low speeds while keeping lag low at high speeds.
    `filter(x, t)` takes the sample and its timestamp in seconds.
    """

    def __init__(self, min_cutoff: float = 1.0, beta: float = 0.02, d_cutoff: float = 1.0):
        if min_cutoff <= 0 or d_cutoff <= 0 or beta < 0:
            raise ValueError("min_cutoff and d_cutoff must be > 0, beta >= 0")
        self.min_cutoff = float(min_cutoff)
        self.beta = float(beta)
        self.d_cutoff = float(d_cutoff)
        self._x_prev: float | None = None
        self._dx_prev = 0.0
        self._t_prev: float | None = None

    def reset(self) -> None:
        self._x_prev = None
        self._dx_prev = 0.0
        self._t_prev = None

    @staticmethod
    def _smoothing(cutoff: float, dt: float) -> float:
        tau = 1.0 / (2.0 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def filter(self, x: float, t: float) -> float:
        if self._x_prev is None or self._t_prev is None or t <= self._t_prev:
            self._x_prev, self._t_prev, self._dx_prev = x, t, 0.0
            return x
        dt = t - self._t_prev
        dx = (x - self._x_prev) / dt
        a_d = self._smoothing(self.d_cutoff, dt)
        dx_hat = a_d * dx + (1.0 - a_d) * self._dx_prev
        cutoff = self.min_cutoff + self.beta * abs(dx_hat)
        a = self._smoothing(cutoff, dt)
        x_hat = a * x + (1.0 - a) * self._x_prev
        self._x_prev, self._dx_prev, self._t_prev = x_hat, dx_hat, t
        return x_hat
