"""Pointer engine: turns sensor packets into cursor actions. Pure logic, no I/O.

Entry points: `handle(packet)` for every sensor packet and `tick(now)` for
time-based transitions. Everything else is driven by the injected clock and
the injected cursor backend, so the whole thing is unit-testable.
"""
from __future__ import annotations

import math
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum

from .config import PointerConfig
from .cursor_backend import CursorBackend, clamp_to_displays, display_containing
from .filters import OneEuroFilter
from .orientation import wrap180, yaw_pitch
from .protocol import SensorPacket


class Phase(StrEnum):
    DISCONNECTED = "disconnected"
    OFF = "off"
    ON = "on"
    RECENTER_HOLD = "hold"
    RECENTER_HELD = "held"


ACTIVE_PHASES = (Phase.ON, Phase.RECENTER_HOLD, Phase.RECENTER_HELD)
MOTION_PHASES = (Phase.ON, Phase.RECENTER_HELD)
DOUBLE_CLICK_RADIUS_PX = 6.0
FILTER_GAP_RESET_S = 0.25


@dataclass
class _ButtonState:
    pressed: bool = False
    counter: int = 0


@dataclass
class _ClickState:
    pending_since: float | None = None
    down: bool = False
    last_click_t: float = -1e9
    last_click_pos: tuple[float, float] = (0.0, 0.0)
    click_count: int = 0


@dataclass(frozen=True)
class Snapshot:
    phase: Phase
    power: bool
    recenter: float
    enabled: bool


class PointerEngine:
    def __init__(self, config: PointerConfig, backend: CursorBackend,
                 clock: Callable[[], float] = time.monotonic):
        self._cfg = config
        self._backend = backend
        self._clock = clock
        self._roles: dict[str, str] = {"left": "left", "right": "right", "scroll": "scroll",
                                       "power": "power"}
        self._enabled = True
        self._phase = Phase.DISCONNECTED
        self._buttons: dict[str, _ButtonState] = {}
        self._clicks = {"left": _ClickState(), "right": _ClickState()}
        self._last_seq = 0
        self._last_rx = 0.0
        self._frozen_until = 0.0
        self._hold_started = 0.0
        self._rest_since: float | None = None
        self._pickup_since: float | None = None
        self._woke_on: set[str] = set()
        self._pickup_armed = True
        self._f_yaw = OneEuroFilter()
        self._f_pitch = OneEuroFilter()
        self._reset_motion()
        self.on_change: Callable[[], None] | None = None

    # ----- external control -------------------------------------------------

    @property
    def phase(self) -> Phase:
        return self._phase

    @property
    def config(self) -> PointerConfig:
        return self._cfg

    def set_config(self, cfg: PointerConfig) -> None:
        self._cfg = cfg
        self._make_filters()
        self._reset_filters()

    def set_roles(self, roles: dict[str, str]) -> None:
        self._roles = dict(roles)
        for bid in list(self._buttons):
            if bid not in self._roles:
                del self._buttons[bid]

    def set_enabled(self, enabled: bool) -> None:
        if not enabled and self._phase in ACTIVE_PHASES:
            self._go_off(self._clock())
        self._enabled = enabled
        self._notify()

    def connected(self) -> None:
        self._buttons.clear()
        self._clicks = {"left": _ClickState(), "right": _ClickState()}
        self._last_seq = 0
        self._frozen_until = 0.0
        self._rest_since = None
        self._pickup_since = None
        self._pickup_armed = True
        self._woke_on.clear()
        self._reset_motion()
        self._set_phase(Phase.OFF)

    def disconnected(self) -> None:
        if self._phase in ACTIVE_PHASES:
            self._go_off(self._clock())
        self._set_phase(Phase.DISCONNECTED)

    def recenter_progress(self, now: float | None = None) -> float:
        if self._phase == Phase.RECENTER_HOLD:
            now = self._clock() if now is None else now
            hold_s = self._cfg.recenter_hold_ms / 1000.0
            return max(0.0, min(1.0, (now - self._hold_started) / hold_s))
        return 1.0 if self._phase == Phase.RECENTER_HELD else 0.0

    def snapshot(self) -> Snapshot:
        return Snapshot(phase=self._phase, power=self._phase in ACTIVE_PHASES,
                        recenter=self.recenter_progress(), enabled=self._enabled)

    # ----- inputs -----------------------------------------------------------

    def handle(self, p: SensorPacket) -> None:
        if self._phase == Phase.DISCONNECTED or p.seq <= self._last_seq:
            return
        self._last_seq = p.seq
        now = self._clock()
        self._last_rx = now
        for role, kind in self._button_events(p):
            self._dispatch(role, kind, now)
        if self._phase in ACTIVE_PHASES:
            self._apply_motion(p, now)
        if self._phase in MOTION_PHASES and "scroll" not in self._woke_on:
            self._apply_scroll(p)
        self._update_rest(p, now)
        self.tick(now)

    def tick(self, now: float | None = None) -> None:
        now = self._clock() if now is None else now
        if self._phase not in ACTIVE_PHASES:
            return
        if now - self._last_rx > self._cfg.timeout_ms / 1000.0:
            self._go_off(now)
            return
        chord_s = self._cfg.chord_window_ms / 1000.0
        if self._phase == Phase.ON:
            for role, st in self._clicks.items():
                if st.pending_since is not None and now - st.pending_since >= chord_s:
                    st.pending_since = None
                    self._press_down(role, st, now)
        if self._phase == Phase.RECENTER_HOLD and \
                now - self._hold_started >= self._cfg.recenter_hold_ms / 1000.0:
            self._snap()
            self._set_phase(Phase.RECENTER_HELD)

    # ----- buttons ----------------------------------------------------------

    def _button_events(self, p: SensorPacket) -> list[tuple[str, str]]:
        events: list[tuple[str, str]] = []
        for bid, role in self._roles.items():
            if bid not in p.buttons and bid not in p.counters:
                continue
            pressed = p.buttons.get(bid, False)
            st = self._buttons.get(bid)
            if st is None:
                # First sighting: adopt the counter silently so stale presses never fire.
                st = _ButtonState(pressed=False, counter=p.counters.get(bid, 0))
                self._buttons[bid] = st
            counter = p.counters.get(bid, st.counter)
            press = counter > st.counter or (pressed and not st.pressed)
            release = (st.pressed or press) and not pressed
            st.pressed, st.counter = pressed, counter
            if press:
                events.append((role, "press"))
            if release:
                events.append((role, "release"))
        return events

    def _dispatch(self, role: str, kind: str, now: float) -> None:
        # Waking on any button means you can point at the cursor, press anything,
        # and start from there. The press is consumed: it would otherwise click
        # whatever happens to be under the cursor, which the user never aimed at.
        if (self._phase == Phase.OFF and self._enabled and self._cfg.wake_on_any_button
                and role != "power"):
            if kind == "press":
                self._power_on(now)
                self._woke_on.add(role)
            return
        if kind == "release" and role in self._woke_on:
            self._woke_on.discard(role)
            return
        if role == "power":
            if kind == "press":
                self._power_press(now)
            else:
                self._power_release(now)
        elif role in ("left", "right"):
            if kind == "press":
                self._click_press(role, now)
            else:
                self._click_release(role, now)
        elif role in ("clutch", "scroll"):
            self._freeze(now, self._cfg.freeze_ms_on_touch if kind == "press"
                         else self._cfg.freeze_ms_on_release)
        elif role == "recenter":
            if kind == "press" and self._phase in MOTION_PHASES:
                self._snap()

    def _power_press(self, now: float) -> None:
        """Tap toggles off, hold recenters. The press only begins the hold; which
        gesture it was is decided on release."""
        if self._phase == Phase.OFF:
            if self._enabled:
                self._power_on(now)
            return
        if self._phase in MOTION_PHASES:
            self._hold_started = now
            self._set_phase(Phase.RECENTER_HOLD)

    def _power_release(self, now: float) -> None:
        if self._phase == Phase.RECENTER_HOLD:
            # Never reached the threshold, so it was a tap.
            self._go_off(now)
        elif self._phase == Phase.RECENTER_HELD:
            self._set_phase(Phase.ON)

    def _toggle_power(self, now: float) -> None:
        if self._phase == Phase.OFF:
            if self._enabled:
                self._power_on(now)
        elif self._phase in ACTIVE_PHASES:
            self._go_off(now)

    def _power_on(self, now: float) -> None:
        self._reset_motion()
        self._last_rx = now
        self._frozen_until = 0.0
        self._set_phase(Phase.ON)

    def _go_off(self, now: float) -> None:
        for role, st in self._clicks.items():
            if st.down:
                self._press_up(role, st)
            st.pending_since = None
        self._frozen_until = 0.0
        self._pickup_armed = False
        self._set_phase(Phase.OFF)

    def _freeze(self, now: float, ms: int) -> None:
        self._frozen_until = max(self._frozen_until, now + ms / 1000.0)

    def _frozen(self, now: float) -> bool:
        if now < self._frozen_until or self._phase == Phase.RECENTER_HOLD:
            return True
        return any(self._buttons.get(bid, _ButtonState()).pressed
                   for bid, role in self._roles.items() if role in ("clutch", "scroll"))

    def _any_button_pressed(self) -> bool:
        """Any layout button at all, not just the click roles."""
        return any(st.pressed for st in self._buttons.values())

    def _any_click_button_pressed(self) -> bool:
        return any(self._buttons.get(bid, _ButtonState()).pressed
                   for bid, role in self._roles.items() if role in ("left", "right"))

    def _click_press(self, role: str, now: float) -> None:
        if self._phase not in MOTION_PHASES:
            return
        self._freeze(now, self._cfg.freeze_ms_on_touch)
        if self._phase == Phase.RECENTER_HELD:
            return
        st = self._clicks[role]
        other = self._clicks["right" if role == "left" else "left"]
        st.pending_since = now
        if other.pending_since is not None and \
                abs(now - other.pending_since) <= self._cfg.chord_window_ms / 1000.0:
            st.pending_since = None
            other.pending_since = None
            self._hold_started = now
            self._set_phase(Phase.RECENTER_HOLD)

    def _click_release(self, role: str, now: float) -> None:
        if self._phase == Phase.RECENTER_HOLD:
            self._freeze(now, self._cfg.freeze_ms_on_release)
            self._set_phase(Phase.ON)
            return
        if self._phase == Phase.RECENTER_HELD:
            if not self._any_click_button_pressed():
                self._set_phase(Phase.ON)
            return
        if self._phase != Phase.ON:
            return
        st = self._clicks[role]
        if st.pending_since is not None:
            st.pending_since = None
            self._press_down(role, st, now)
            self._press_up(role, st)
        elif st.down:
            self._press_up(role, st)
        self._freeze(now, self._cfg.freeze_ms_on_release)

    def _press_down(self, role: str, st: _ClickState, now: float) -> None:
        x, y = self._backend.get_position()
        near = math.hypot(x - st.last_click_pos[0], y - st.last_click_pos[1]) <= DOUBLE_CLICK_RADIUS_PX
        if now - st.last_click_t <= self._cfg.double_click_s and near:
            st.click_count = min(st.click_count + 1, 3)
        else:
            st.click_count = 1
        st.last_click_t = now
        st.last_click_pos = (x, y)
        st.down = True
        self._backend.button_down(role, x, y, st.click_count)  # type: ignore[arg-type]

    def _press_up(self, role: str, st: _ClickState) -> None:
        x, y = self._backend.get_position()
        st.down = False
        self._backend.button_up(role, x, y, st.click_count)  # type: ignore[arg-type]

    # ----- motion -----------------------------------------------------------

    def _make_filters(self) -> None:
        oe = self._cfg.one_euro
        self._f_yaw = OneEuroFilter(oe.min_cutoff, oe.beta, oe.d_cutoff)
        self._f_pitch = OneEuroFilter(oe.min_cutoff, oe.beta, oe.d_cutoff)

    def _reset_filters(self) -> None:
        self._f_yaw.reset()
        self._f_pitch.reset()
        self._prev_f: tuple[float, float] | None = None
        self._anchor = None  # re-anchor on the next packet, or the cursor jumps

    def _reset_motion(self) -> None:
        self._make_filters()
        self._reset_filters()
        self._yaw_raw_prev: float | None = None
        self._yaw_cont = 0.0
        self._last_ts: float | None = None
        self._carry = [0.0, 0.0]
        self._scroll_carry = 0.0
        self._anchor: tuple[float, float] | None = None
        self._anchor_pos: tuple[float, float] = (0.0, 0.0)

    def _apply_motion(self, p: SensorPacket, now: float) -> None:
        if not p.has_orientation:
            return
        yaw, pitch = yaw_pitch(p.alpha, p.beta, p.gamma or 0.0)  # type: ignore[arg-type]
        if self._yaw_raw_prev is None:
            self._yaw_cont = yaw
        else:
            self._yaw_cont += wrap180(yaw - self._yaw_raw_prev)
        self._yaw_raw_prev = yaw
        dt = 0.0
        if self._last_ts is not None:
            dt = p.ts - self._last_ts
            if dt > FILTER_GAP_RESET_S or dt <= 0:
                self._reset_filters()
        self._last_ts = p.ts
        yf = self._f_yaw.filter(self._yaw_cont, p.ts)
        pf = self._f_pitch.filter(pitch, p.ts)
        prev, self._prev_f = self._prev_f, (yf, pf)
        frozen = self._frozen(now)
        if self._cfg.mapping == "absolute":
            self._apply_absolute(yf, pf, frozen, p.rate_dps)
            return
        if prev is None or frozen or p.rate_dps < self._cfg.deadzone_dps:
            return
        dyaw, dpitch = yf - prev[0], pf - prev[1]
        mult = 1.0
        ac = self._cfg.accel
        if ac.enabled and dt > 0:
            speed = math.hypot(dyaw, dpitch) / dt
            mult = max(1.0, min(ac.max_mult, 1.0 + ac.k * max(0.0, speed - ac.threshold_dps)))
        dx = dyaw * self._cfg.gain_x_px_per_deg * mult
        dy = -dpitch * self._cfg.gain_y_px_per_deg * mult
        if self._cfg.invert_y:
            dy = -dy
        self._move_by(dx, dy)

    def _apply_absolute(self, yaw: float, pitch: float, frozen: bool, rate_dps: float) -> None:
        """Map aim directly onto the screen, anchored where the pointer was armed.

        This is the Wii-like mapping: the cursor is a function of where you are
        pointing, not of how far you have turned, so aim and cursor cannot drift
        apart. The anchor re-tracks continuously while the cursor is frozen, for
        the same reason the relative filter reference does: otherwise releasing a
        clutch or a scroll strip snaps the cursor by however far you turned while
        it was held.
        """
        if self._anchor is None or frozen:
            self._anchor = (yaw, pitch)
            self._anchor_pos = self._backend.get_position()
            return
        if rate_dps < self._cfg.deadzone_dps:
            return  # hold still; do not re-anchor, or slow aiming could never move
        dx = self._curve(yaw - self._anchor[0]) * self._cfg.gain_x_px_per_deg
        dy = -self._curve(pitch - self._anchor[1]) * self._cfg.gain_y_px_per_deg
        if self._cfg.invert_y:
            dy = -dy
        self._move_to(*self._absorb_overshoot(self._anchor_pos[0] + dx,
                                              self._anchor_pos[1] + dy))

    def _absorb_overshoot(self, tx: float, ty: float) -> tuple[float, float]:
        """Stop aim past a screen edge accumulating without bound.

        Absolute mapping parks the cursor at the edge while you aim beyond it, and
        that is wanted -- but the discarded overshoot is unbounded, so aiming well
        off-screen meant un-aiming nearly all of it before the cursor would move
        again. The anchor absorbs everything past `edge_slack_px`, leaving a small
        deliberate amount of stick and no more.
        """
        bx, by = self._backend.get_position()
        displays = self._backend.displays()
        current = display_containing(displays, bx, by)
        cx, cy = clamp_to_displays(displays, tx, ty, current)
        slack = self._cfg.edge_slack_px
        ax, ay = self._anchor_pos
        ex, ey = tx - cx, ty - cy
        if abs(ex) > slack:
            ax -= ex - math.copysign(slack, ex)
        if abs(ey) > slack:
            ay -= ey - math.copysign(slack, ey)
        self._anchor_pos = (ax, ay)
        return cx, cy

    def _curve(self, degrees: float) -> float:
        """Expo: amplify large offsets from the anchor, leave small ones alone.

        Spanning a wide screen at a linear gain demands a big arm movement, but
        raising the gain everywhere costs precision. Growing the gain with
        distance from the anchor keeps small corrections one-to-one while making
        edge-to-edge sweeps cheap. Still a pure function of aim, so the absolute
        mapping's no-drift property survives.
        """
        cfg = self._cfg
        if cfg.expo <= 0.0:
            return degrees
        mult = 1.0 + cfg.expo * (abs(degrees) / cfg.expo_ref_deg) ** 2
        return degrees * min(mult, cfg.expo_max)

    def _move_to(self, tx: float, ty: float) -> None:
        """Move to an absolute target, clamped across displays, dragging if held."""
        bx, by = self._backend.get_position()
        displays = self._backend.displays()
        current = display_containing(displays, bx, by)
        tx, ty = clamp_to_displays(displays, int(tx), int(ty), current)
        if (tx, ty) == (bx, by):
            return
        held = ("left" if self._clicks["left"].down
                else "right" if self._clicks["right"].down else None)
        if held:
            self._backend.drag_to(tx, ty, held)  # type: ignore[arg-type]
        else:
            self._backend.move_to(tx, ty)

    def _move_by(self, dx: float, dy: float) -> None:
        self._carry[0] += dx
        self._carry[1] += dy
        ix, iy = int(self._carry[0]), int(self._carry[1])
        if ix == 0 and iy == 0:
            return
        self._carry[0] -= ix
        self._carry[1] -= iy
        bx, by = self._backend.get_position()
        displays = self._backend.displays()
        current = display_containing(displays, bx, by)
        tx, ty = clamp_to_displays(displays, bx + ix, by + iy, current)
        if (tx, ty) == (bx, by):
            return  # pinned at an edge: overshoot is discarded (edge drag)
        held = ("left" if self._clicks["left"].down
                else "right" if self._clicks["right"].down else None)
        if held:
            self._backend.drag_to(tx, ty, held)  # type: ignore[arg-type]
        else:
            self._backend.move_to(tx, ty)

    def _snap(self) -> None:
        bx, by = self._backend.get_position()
        cx, cy = display_containing(self._backend.displays(), bx, by).center()
        self._backend.move_to(cx, cy)
        self._reset_motion()

    def _apply_scroll(self, p: SensorPacket) -> None:
        if p.scroll_delta == 0:
            return
        direction = 1.0 if self._cfg.scroll_natural else -1.0
        self._scroll_carry += p.scroll_delta * self._cfg.scroll_gain * direction
        step = int(self._scroll_carry)
        if step:
            self._scroll_carry -= step
            self._backend.scroll(step)

    # ----- rest / pickup ----------------------------------------------------

    def _update_rest(self, p: SensorPacket, now: float) -> None:
        if not p.has_orientation:
            return
        cfg = self._cfg
        rest_pose = abs(p.beta) < cfg.rest_tilt_deg and abs(p.gamma or 0.0) < cfg.rest_tilt_deg  # type: ignore[arg-type]
        still = p.rate_dps < cfg.rest_rate_dps
        if rest_pose:
            self._pickup_armed = True
            self._pickup_since = None
        elif self._pickup_since is None:
            self._pickup_since = now
        # A held button means the user is demonstrably holding the device. Aiming
        # at a screen keeps the phone near-flat, which is geometrically identical
        # to lying on a desk -- and the recenter gesture is *defined* as holding
        # both buttons still for a second, which was exactly the rest condition.
        in_use = self._any_button_pressed() or self._phase in (Phase.RECENTER_HOLD,
                                                               Phase.RECENTER_HELD)
        if rest_pose and still and not in_use:
            if self._rest_since is None:
                self._rest_since = now
            elif now - self._rest_since >= cfg.rest_seconds and self._phase in ACTIVE_PHASES \
                    and cfg.auto_deactivate:
                self._go_off(now)
        else:
            self._rest_since = None
        if cfg.auto_activate and self._enabled and self._phase == Phase.OFF and self._pickup_armed \
                and self._pickup_since is not None \
                and now - self._pickup_since >= cfg.pickup_ms / 1000.0:
            self._power_on(now)

    # ----- misc -------------------------------------------------------------

    def _set_phase(self, phase: Phase) -> None:
        if phase != self._phase:
            self._phase = phase
            self._notify()

    def _notify(self) -> None:
        if self.on_change:
            self.on_change()
