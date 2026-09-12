"""Behavioral tests for the pointer engine, driven with a fake clock and a fake cursor."""
import json

import pytest

from phice.config import PointerConfig
from phice.cursor_backend import FakeCursor, Rect
from phice.engine import Phase, PointerEngine
from phice.protocol import parse_client_message

DT = 1 / 60


class Clock:
    def __init__(self, t=0.0):
        self.t = t

    def __call__(self):
        return self.t


class Rig:
    """Helper that owns clock, cursor and engine and makes sending packets terse."""

    def __init__(self, cfg=None, cursor=None, roles=None):
        self.clock = Clock(10.0)
        self.cursor = cursor or FakeCursor()
        self.engine = PointerEngine(cfg or PointerConfig(), self.cursor, self.clock)
        if roles:
            self.engine.set_roles(roles)
        self.engine.connected()
        self.seq = 0
        # The real page reports every layout button in every packet, so mirror that.
        ids = list(roles) if roles else ["left", "right", "scroll", "power"]
        self.buttons = {b: False for b in ids}
        self.counters = {b: 0 for b in ids}

    def send(self, alpha=0.0, beta=0.0, gamma=0.0, rr=(10.0, 0.0, 0.0), sd=0.0, advance=DT, **presses):
        """Send one packet. presses: left=True/False etc. changes button state (counts presses)."""
        for bid, pressed in presses.items():
            if pressed and not self.buttons.get(bid, False):
                self.counters[bid] = self.counters.get(bid, 0) + 1
            self.buttons[bid] = pressed
        self.clock.t += advance
        self.seq += 1
        text = json.dumps({"t": "s", "seq": self.seq, "ts": self.clock.t, "o": [alpha, beta, gamma],
                           "rr": list(rr), "g": [0, 0, 9.8],
                           "b": {k: int(v) for k, v in self.buttons.items()},
                           "c": dict(self.counters), "sd": sd})
        self.engine.handle(parse_client_message(text))

    def stream(self, n, **kw):
        for _ in range(n):
            self.send(**kw)

    def power(self):
        self.send(power=True)
        self.send(power=False)

    def tick(self, advance):
        self.clock.t += advance
        self.engine.tick(self.clock.t)


def test_off_ignores_motion():
    r = Rig()
    assert r.engine.phase == Phase.OFF
    r.stream(30, alpha=350)
    assert r.cursor.events == []


def test_power_on_keeps_cursor_where_it_is():
    r = Rig()
    r.power()
    assert r.engine.phase == Phase.ON
    assert r.cursor.events == []
    assert r.engine.snapshot().power is True


def test_turning_right_moves_right_by_gain():
    # expo off: this measures the linear gain, not the feel curve.
    r = Rig(PointerConfig(expo=0.0))
    r.power()
    r.stream(5, alpha=0)
    r.stream(90, alpha=350)  # 10 degrees to the right, filter settles within ~1 s
    assert r.cursor.y == 100
    assert r.cursor.x == pytest.approx(100 + 250, abs=3)
    assert all(k == "move" for k in r.cursor.kinds())


def test_raising_top_edge_moves_up():
    r = Rig(PointerConfig(expo=0.0), cursor=FakeCursor(x=700, y=500))
    r.power()
    r.stream(5, beta=0)
    r.stream(90, beta=10)
    assert r.cursor.x == 700
    assert r.cursor.y == pytest.approx(500 - 250, abs=3)


def test_invert_y_flips_vertical():
    r = Rig(PointerConfig(invert_y=True, expo=0.0), cursor=FakeCursor(x=700, y=500))
    r.power()
    r.stream(5, beta=0)
    r.stream(90, beta=10)
    assert r.cursor.y == pytest.approx(500 + 250, abs=3)


def test_roll_never_moves_cursor():
    r = Rig(cursor=FakeCursor(x=700, y=500))
    r.power()
    r.stream(90, alpha=30, beta=10, gamma=0)  # settle on the new aim
    r.cursor.clear()
    for i in range(60):
        r.send(alpha=30, beta=10, gamma=(i % 30) * 3 - 45)
    assert r.cursor.events == []


def test_yaw_wraps_across_zero():
    r = Rig(PointerConfig(expo=0.0), cursor=FakeCursor(x=700, y=500))
    r.power()
    r.stream(90, alpha=5)  # 5 degrees left of the power-on aim
    assert r.cursor.x == pytest.approx(700 - 125, abs=3)
    r.stream(90, alpha=355)  # crossing 0 -> right by 10 degrees, not a 350-degree jump
    assert r.cursor.x == pytest.approx(700 + 125, abs=3)


def test_deadzone_discards_slow_creep():
    r = Rig()
    r.power()
    r.stream(5, alpha=0)
    r.stream(60, alpha=359, rr=(0.1, 0, 0))
    assert r.cursor.events == []


def test_touch_freezes_then_pending_becomes_down():
    r = Rig()
    r.power()
    r.stream(5, alpha=0)
    r.send(alpha=0, left=True)  # press at t0
    r.stream(2, alpha=340)  # within chord window: nothing yet
    assert r.cursor.events == []
    r.stream(2, alpha=340)  # > 50 ms: mouse-down fires at the frozen position
    assert r.cursor.kinds() == ["down"]
    assert r.cursor.events[0].x == 100 and r.cursor.events[0].count == 1
    r.stream(3, alpha=340)  # t0 + 116 ms: still inside the 120 ms freeze
    assert r.cursor.kinds() == ["down"]
    r.stream(30, alpha=340)  # freeze over: motion becomes a drag
    assert r.cursor.kinds()[1] == "drag"
    assert "move" not in r.cursor.kinds()
    r.send(alpha=340, left=False)
    assert r.cursor.kinds()[-1] == "up"
    assert r.cursor.held == set()


def test_short_tap_is_a_click_at_the_touch_position():
    r = Rig()
    r.power()
    r.send(left=True)
    r.send(left=False)
    assert r.cursor.kinds() == ["down", "up"]
    assert (r.cursor.events[0].x, r.cursor.events[0].y) == (100, 100)


def test_missed_tap_is_recovered_from_counter():
    r = Rig()
    r.power()
    r.counters["left"] += 1  # page counted a press, but the packet with b.left=1 was lost
    r.send()
    assert r.cursor.kinds() == ["down", "up"]


def test_reconnect_does_not_replay_stale_counters():
    r = Rig()
    r.power()
    r.engine.connected()  # e.g. the phone's socket dropped and came back
    r.counters.update({"left": 7, "right": 3})  # counters kept climbing in the page
    r.send()  # first packet after reconnect: adopted as the baseline, silently
    r.power()
    r.send()
    assert r.cursor.kinds() == []


def test_right_button_clicks():
    r = Rig()
    r.power()
    r.send(right=True)
    r.tick(0.1)
    r.send(right=False)
    assert [(e.kind, e.button) for e in r.cursor.events] == [("down", "right"), ("up", "right")]


def test_double_click_count():
    r = Rig()
    r.power()
    r.send(left=True)
    r.send(left=False)
    r.send(left=True)
    r.send(left=False)
    r.stream(60)  # a second passes (packets keep flowing, so no timeout)
    r.send(left=True)
    r.send(left=False)
    counts = [e.count for e in r.cursor.events if e.kind == "down"]
    assert counts == [1, 2, 1]


def test_chord_produces_no_click_and_cancels_on_early_release():
    r = Rig()
    r.power()
    r.send(left=True)
    r.send(right=True)  # 16 ms later: chord
    assert r.engine.phase == Phase.RECENTER_HOLD
    r.stream(20, alpha=340)  # frozen while holding
    assert r.cursor.events == []
    r.send(alpha=340, right=False)  # released before 1 s
    assert r.engine.phase == Phase.ON
    r.send(alpha=340, left=False)
    r.stream(30, alpha=340)
    assert r.cursor.events == []


def test_chord_hold_snaps_to_center_and_suppresses_clicks():
    r = Rig(PointerConfig(expo=0.0))
    r.power()
    r.send(left=True)
    r.send(right=True)
    assert 0.0 <= r.engine.recenter_progress() < 0.1
    r.stream(70, alpha=0)  # > 1 s of holding
    assert r.engine.phase == Phase.RECENTER_HELD
    assert r.cursor.kinds() == ["move"]
    assert (r.cursor.x, r.cursor.y) == (720, 450)
    assert r.engine.recenter_progress() == 1.0
    r.stream(5, alpha=0)
    r.stream(60, alpha=350)  # motion works while still holding
    assert r.cursor.x == pytest.approx(720 + 250, abs=3)
    assert "down" not in r.cursor.kinds()
    r.send(alpha=350, left=False)
    r.send(alpha=350, left=True)  # re-press while right is still held: still no click
    r.send(alpha=350, left=False)
    r.tick(0.2)
    assert "down" not in r.cursor.kinds()
    assert r.engine.phase == Phase.RECENTER_HELD
    r.send(alpha=350, right=False)
    assert r.engine.phase == Phase.ON


def test_two_buttons_outside_chord_window_both_click():
    r = Rig()
    r.power()
    r.send(left=True)
    r.tick(0.1)
    r.send(right=True)
    r.tick(0.1)
    r.send(left=False, right=False)
    assert [e.kind for e in r.cursor.events] == ["down", "down", "up", "up"]


def test_scroll_natural_and_inverted():
    r = Rig(PointerConfig(scroll_natural=True))
    r.power()
    r.send(scroll=True, sd=-10)
    assert [(e.kind, e.dy) for e in r.cursor.events] == [("scroll", -15)]
    r2 = Rig(PointerConfig(scroll_natural=False))
    r2.power()
    r2.send(scroll=True, sd=-10)
    assert r2.cursor.events[0].dy == 15


def test_scroll_carries_fractions():
    r = Rig(PointerConfig(scroll_gain=0.5, scroll_natural=True))
    r.power()
    r.send(scroll=True, sd=1)
    r.send(scroll=True, sd=1)
    assert [e.dy for e in r.cursor.events] == [1]


def test_scroll_touch_freezes_cursor():
    r = Rig()
    r.power()
    r.stream(5, alpha=0)
    r.send(alpha=0, scroll=True)
    r.stream(30, alpha=340, sd=0)
    assert "move" not in r.cursor.kinds()
    r.send(alpha=340, scroll=False)
    r.stream(30, alpha=340)
    assert r.cursor.kinds() == []  # reference re-synced while frozen: no jump after release
    r.stream(30, alpha=330)
    assert "move" in r.cursor.kinds()


def test_clutch_freezes_cursor():
    r = Rig(roles={"left": "left", "right": "right", "power": "power", "hold": "clutch"})
    r.power()
    r.stream(5, alpha=0)
    r.send(alpha=0, hold=True)
    r.stream(30, alpha=340)
    assert r.cursor.events == []
    r.send(alpha=340, hold=False)
    r.stream(30, alpha=340)
    assert r.cursor.kinds() == []  # reference re-synced while frozen: no jump after release
    r.stream(30, alpha=330)
    assert r.cursor.x > 100


def test_recenter_button_role_snaps_immediately():
    r = Rig(roles={"left": "left", "right": "right", "power": "power", "rc": "recenter"})
    r.power()
    r.send(rc=True)
    assert r.cursor.kinds() == ["move"] and (r.cursor.x, r.cursor.y) == (720, 450)
    assert r.engine.phase == Phase.ON


def test_edge_clamp_and_edge_drag():
    """Relative mapping: overshoot past an edge is discarded, so turning back
    moves immediately. That is the 're-grip' property absolute mapping gives up."""
    r = Rig(PointerConfig(mapping="relative"), cursor=FakeCursor(x=1435, y=100))
    r.power()
    r.stream(5, alpha=0)
    r.stream(60, alpha=350)  # far past the right edge
    assert r.cursor.x == 1439
    r.stream(5, alpha=350)
    r.cursor.clear()
    r.stream(60, alpha=355)  # turning back 5 degrees moves immediately
    assert r.cursor.x == pytest.approx(1439 - 125, abs=3)


def test_multi_display_crossing_and_clamp():
    cursor = FakeCursor(x=1435, y=100, display_list=[Rect(0, 0, 1440, 900), Rect(1440, 0, 1920, 1080)])
    r = Rig(cursor=cursor)
    r.power()
    r.stream(5, alpha=0)
    r.stream(60, alpha=359)  # 1 degree right = 25 px, crosses into the second display
    assert r.cursor.x == pytest.approx(1460, abs=3)
    r.stream(60, beta=-40)  # far below both displays: clamped to the current one's bottom
    assert r.cursor.y == 1079


def test_timeout_releases_buttons_and_turns_off():
    r = Rig()
    r.power()
    r.send(left=True)
    r.tick(0.1)
    assert r.cursor.held == {"left"}
    r.tick(0.6)
    assert r.cursor.held == set() and r.cursor.kinds()[-1] == "up"
    assert r.engine.phase == Phase.OFF


def test_disconnect_releases_buttons():
    r = Rig()
    r.power()
    r.send(left=True)
    r.tick(0.1)
    r.engine.disconnected()
    assert r.cursor.held == set()
    assert r.engine.phase == Phase.DISCONNECTED
    r.send(alpha=350)
    assert r.engine.phase == Phase.DISCONNECTED


def test_kill_switch():
    r = Rig()
    r.power()
    r.engine.set_enabled(False)
    assert r.engine.phase == Phase.OFF
    r.power()
    assert r.engine.phase == Phase.OFF
    r.engine.set_enabled(True)
    r.power()
    assert r.engine.phase == Phase.ON


def test_sequence_regression_is_dropped():
    r = Rig()
    r.power()
    r.seq = 50
    r.send(left=True)
    r.seq = 10  # next packet gets seq 11 < 51
    r.send(left=False)
    r.tick(0.1)
    assert r.cursor.kinds() == ["down"]  # release never seen


def test_auto_deactivate_at_rest():
    r = Rig(PointerConfig(rest_seconds=1.0))
    r.power()
    r.stream(70, beta=0, gamma=0, rr=(0.5, 0.5, 0.5))
    assert r.engine.phase == Phase.OFF


def test_auto_deactivate_can_be_disabled():
    r = Rig(PointerConfig(auto_deactivate=False))
    r.power()
    r.stream(120, beta=0, gamma=0, rr=(0.5, 0.5, 0.5))
    assert r.engine.phase == Phase.ON


def test_auto_activate_after_pickup_but_not_after_manual_off():
    r = Rig(PointerConfig(auto_activate=True))
    r.stream(5, beta=0)  # resting: arms pickup
    r.stream(25, beta=40)  # lifted for > 300 ms
    assert r.engine.phase == Phase.ON
    r.send(beta=40, power=True)
    r.send(beta=40, power=False)
    assert r.engine.phase == Phase.OFF
    r.stream(60, beta=40)  # still raised: must not re-activate
    assert r.engine.phase == Phase.OFF
    r.stream(5, beta=0, rr=(0.1, 0, 0))  # put down: re-arms
    r.stream(25, beta=40)
    assert r.engine.phase == Phase.ON


def test_gap_in_packets_resets_filter_without_jump():
    r = Rig()
    r.power()
    r.stream(5, alpha=0)
    r.send(alpha=350, advance=0.5)  # half-second gap: filters reset, no delta applied
    assert r.cursor.events == []
    r.stream(60, alpha=350)
    assert r.cursor.events == []  # same angle after reset: nothing moves


def test_set_config_applies_new_gain():
    r = Rig(PointerConfig(expo=0.0))
    r.power()
    r.stream(5, alpha=0)
    r.engine.set_config(PointerConfig(gain_x_px_per_deg=50.0, expo=0.0))
    r.stream(5, alpha=0)
    r.stream(90, alpha=350)
    assert r.cursor.x == pytest.approx(100 + 500, abs=5)


def test_change_callback_fires_on_phase_change():
    """A power tap now passes through RECENTER_HOLD: the press starts the hold and
    the release decides it was a tap."""
    r = Rig()
    seen = []
    r.engine.on_change = lambda: seen.append(r.engine.phase)
    r.power()
    r.power()
    assert seen == [Phase.ON, Phase.RECENTER_HOLD, Phase.OFF]


def test_absolute_edge_clamp_parks_then_returns():
    """Parks at the edge while you aim past it, and comes back when you aim back.
    Overshoot beyond edge_slack_px is absorbed, so the return is prompt rather
    than requiring you to un-aim the whole excursion."""
    r = Rig(PointerConfig(expo=0.0), cursor=FakeCursor(x=1435, y=100))
    r.power()
    r.stream(5, alpha=0)
    r.stream(60, alpha=350)  # +10 deg -> 1685, clamped to the edge
    assert r.cursor.x == 1439
    r.stream(90, alpha=0)  # aim back -> cursor comes off the edge
    assert r.cursor.x < 1439


def test_absolute_aim_and_cursor_do_not_drift_apart():
    """Return to the same aim and the cursor returns to the same pixel, however
    much turning happened in between. Relative integration cannot promise this."""
    # A display large enough that the sweep never reaches an edge: clamping is a
    # separate behaviour with its own tests.
    r = Rig(cursor=FakeCursor(x=4000, y=2000,
                              display_list=[Rect(0, 0, 8000, 4000)]))
    r.power()
    r.stream(90, alpha=0)
    home = (r.cursor.x, r.cursor.y)
    for alpha in (350, 10, 340, 20, 0):
        r.stream(60, alpha=alpha)
    assert (r.cursor.x, r.cursor.y) == pytest.approx(home, abs=3)


def test_absolute_clutch_reanchors_without_jumping():
    r = Rig(roles={"left": "left", "right": "right", "power": "power", "hold": "clutch"})
    r.power()
    r.stream(30, alpha=0)
    r.send(alpha=0, hold=True)
    r.stream(60, alpha=330)  # turn 30 deg while clutched: cursor must not move
    assert r.cursor.events == []
    r.send(alpha=330, hold=False)
    r.cursor.clear()
    r.stream(5, alpha=330)
    assert r.cursor.events == []  # released at the new aim: still no jump


def test_recenter_hold_does_not_trigger_auto_deactivate():
    """Holding both buttons still for a second IS the recenter gesture, and it is
    also exactly what rest detection looks for: flat, still, for rest_seconds.
    Recentering used to snap to centre and then immediately power off."""
    r = Rig(PointerConfig(recenter_hold_ms=1000, rest_seconds=1.0, auto_deactivate=True))
    r.power()
    r.send(left=True)
    r.send(right=True)
    # Hold perfectly still and flat for well over both timers.
    r.stream(150, alpha=0, beta=0, gamma=0, rr=(0.2, 0.2, 0.2))
    assert r.engine.phase == Phase.RECENTER_HELD
    r.send(alpha=0, left=False)
    r.send(alpha=0, right=False)
    assert r.engine.phase == Phase.ON


def test_holding_any_button_prevents_auto_deactivate():
    """A held button means the user is demonstrably holding the device. Aiming at
    a screen keeps the phone near-flat, which is geometrically the same as lying
    on a desk, so button state is the discriminator."""
    r = Rig(PointerConfig(rest_seconds=0.5, auto_deactivate=True))
    r.power()
    r.send(left=True)
    r.stream(120, beta=0, gamma=0, rr=(0.1, 0.1, 0.1))
    assert r.engine.phase == Phase.ON, "held button must keep it awake"
    r.send(beta=0, left=False)
    r.stream(120, beta=0, gamma=0, rr=(0.1, 0.1, 0.1))
    assert r.engine.phase == Phase.OFF, "released and at rest: may power off"


def test_expo_amplifies_large_sweeps_but_not_small_ones():
    """Spanning the screen should not demand a huge arm movement, while small
    corrections stay one-to-one for precision."""
    linear = Rig(PointerConfig(expo=0.0), cursor=FakeCursor(x=720, y=450,
                  display_list=[Rect(0, 0, 4000, 2000)]))
    curved = Rig(PointerConfig(expo=1.0), cursor=FakeCursor(x=720, y=450,
                  display_list=[Rect(0, 0, 4000, 2000)]))
    for r in (linear, curved):
        r.power()
        r.stream(90, alpha=0)
    # A small turn: both should travel about the same distance.
    for r in (linear, curved):
        r.stream(90, alpha=358)
    small_lin = linear.cursor.x - 720
    small_cur = curved.cursor.x - 720
    assert abs(small_cur - small_lin) < 0.35 * abs(small_lin), "small moves stay precise"
    # A large turn: expo should travel meaningfully further.
    for r in (linear, curved):
        r.stream(120, alpha=320)
    big_lin = linear.cursor.x - 720
    big_cur = curved.cursor.x - 720
    assert big_cur > big_lin * 1.5, f"large sweeps amplified: {big_cur} vs {big_lin}"


def test_expo_zero_is_exactly_linear():
    r = Rig(PointerConfig(expo=0.0), cursor=FakeCursor(x=700, y=500))
    r.power()
    r.stream(5, alpha=0)
    r.stream(90, alpha=350)
    assert r.cursor.x == pytest.approx(700 + 250, abs=3)


def _no_power_roles():
    return {"left": "left", "right": "right", "scroll": "scroll"}


def test_any_button_wakes_the_pointer_and_is_consumed():
    """With no power button, the first press on anything arms the pointer and
    anchors where the cursor already is. It must not also click: you would be
    clicking whatever happens to be under the cursor."""
    r = Rig(roles=_no_power_roles())
    assert r.engine.phase == Phase.OFF
    r.send(left=True)
    assert r.engine.phase == Phase.ON
    assert r.cursor.events == [], "the waking press must not click"
    r.send(left=False)
    assert r.cursor.events == [], "nor should its release"


def test_a_press_after_waking_clicks_normally():
    r = Rig(roles=_no_power_roles())
    r.send(left=True)          # wakes
    r.send(left=False)
    r.tick(0.2)
    r.send(left=True)          # now a real click
    r.send(left=False)
    assert [e.kind for e in r.cursor.events] == ["down", "up"]


def test_scroll_also_wakes_it():
    r = Rig(roles=_no_power_roles())
    r.send(scroll=True, sd=-10)
    assert r.engine.phase == Phase.ON
    assert r.cursor.events == [], "the waking touch must not scroll"


def test_waking_anchors_at_the_current_cursor_position():
    """'Point at the cursor and press' only works if waking anchors there."""
    r = Rig(roles=_no_power_roles(), cursor=FakeCursor(x=900, y=300))
    r.send(alpha=40, left=True)
    r.send(alpha=40, left=False)
    r.stream(90, alpha=40)
    assert (r.cursor.x, r.cursor.y) == (900, 300), "no jump on wake"


def test_wake_on_any_button_can_be_disabled():
    r = Rig(PointerConfig(wake_on_any_button=False), roles=_no_power_roles())
    r.send(left=True)
    assert r.engine.phase == Phase.OFF


def test_power_button_still_works_when_present():
    """Existing layouts that keep a power button must behave as before."""
    r = Rig()
    r.power()
    assert r.engine.phase == Phase.ON
    r.power()
    assert r.engine.phase == Phase.OFF


def test_power_tap_turns_it_off():
    """A quick tap is the off switch; a hold is recenter. They must not collide."""
    r = Rig()
    r.send(left=True)
    r.send(left=False)      # wake
    assert r.engine.phase == Phase.ON
    r.send(power=True)
    assert r.engine.phase == Phase.RECENTER_HOLD, "press begins the hold"
    r.send(power=False)                         # released well before the threshold
    assert r.engine.phase == Phase.OFF, "short press is a tap: power off"


def test_power_hold_recenters_without_turning_off():
    r = Rig(cursor=FakeCursor(x=100, y=100))
    r.send(left=True)
    r.send(left=False)
    r.send(power=True)
    r.stream(70, alpha=0)                       # past recenter_hold_ms
    assert r.engine.phase == Phase.RECENTER_HELD
    assert (r.cursor.x, r.cursor.y) == (720, 450), "snapped to the display centre"
    r.send(alpha=0, power=False)
    assert r.engine.phase == Phase.ON, "still on after recentering"


def test_power_hold_reports_progress_for_the_animation():
    r = Rig()
    r.send(left=True)
    r.send(left=False)
    assert r.engine.recenter_progress() == 0.0
    r.send(power=True)
    r.stream(30, alpha=0)                       # roughly half of the 1s hold
    mid = r.engine.recenter_progress()
    assert 0.2 < mid < 0.9, f"progress should climb steadily, got {mid}"
    r.stream(40, alpha=0)
    assert r.engine.recenter_progress() == 1.0


def test_power_while_off_turns_it_on():
    r = Rig()
    assert r.engine.phase == Phase.OFF
    r.send(power=True)
    assert r.engine.phase == Phase.ON
    r.send(power=False)
    assert r.engine.phase == Phase.ON, "the release must not immediately toggle it off"


def test_edge_overshoot_is_bounded_so_the_cursor_peels_off_quickly():
    """Absolute mapping parks at the edge while you aim past it, but the discarded
    overshoot must not accumulate: aiming far off-screen used to mean un-aiming
    almost all of it before the cursor would move at all."""
    r = Rig(cursor=FakeCursor(x=1435, y=400))
    r.send(left=True)
    r.send(left=False)
    r.stream(30, alpha=0)
    r.stream(120, alpha=300)     # 60 degrees right: enormously past the edge
    assert r.cursor.x == 1439, "parked at the edge"
    r.cursor.clear()
    # Turn back just a few degrees. With bounded overshoot this must move.
    r.stream(60, alpha=355)
    assert r.cursor.x < 1439, "cursor should peel off the edge almost immediately"


def test_a_little_edge_stick_remains():
    """Some stick is wanted: a hair of overshoot should not instantly unstick."""
    r = Rig(PointerConfig(edge_slack_px=24.0), cursor=FakeCursor(x=1435, y=400))
    r.send(left=True)
    r.send(left=False)
    r.stream(30, alpha=0)
    r.stream(90, alpha=358)      # 2 degrees right: just past the edge
    assert r.cursor.x == 1439
    r.cursor.clear()
    r.stream(5, alpha=357.9)     # a hair back: still inside the slack
    assert r.cursor.x == 1439, "a tiny bit of stick is intentional"


def test_edge_slack_does_not_affect_the_interior():
    """Nothing about the slack may perturb normal aiming away from an edge."""
    r = Rig(PointerConfig(expo=0.0), cursor=FakeCursor(x=700, y=500))
    r.send(left=True)
    r.send(left=False)
    r.stream(5, alpha=0)
    r.stream(90, alpha=350)
    assert r.cursor.x == pytest.approx(700 + 250, abs=3)
