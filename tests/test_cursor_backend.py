from phice.cursor_backend import (
    FakeCursor,
    QuartzCursor,
    Rect,
    clamp_to_displays,
    display_containing,
)

MAIN = Rect(0, 0, 1440, 900)
SIDE = Rect(1440, 0, 1920, 1080)


def test_rect_contains_and_clamp():
    assert MAIN.contains(0, 0) and MAIN.contains(1439, 899)
    assert not MAIN.contains(1440, 0) and not MAIN.contains(-1, 5)
    assert MAIN.clamp(2000, -50) == (1439, 0)
    assert MAIN.center() == (720, 450)


def test_display_containing_prefers_holder_then_nearest():
    assert display_containing([MAIN, SIDE], 1500, 10) == SIDE
    assert display_containing([MAIN, SIDE], 10, 10) == MAIN
    assert display_containing([MAIN, SIDE], 1500, 1500) == SIDE
    assert display_containing([MAIN, SIDE], -100, -100) == MAIN


def test_clamp_allows_crossing_into_neighbor():
    assert clamp_to_displays([MAIN, SIDE], 1450, 100, MAIN) == (1450, 100)
    assert clamp_to_displays([MAIN, SIDE], 1450, 1100, MAIN) == (1439, 899)
    assert clamp_to_displays([MAIN, SIDE], -5, 100, MAIN) == (0, 100)


def test_fake_cursor_records():
    f = FakeCursor()
    f.move_to(5, 6)
    f.button_down("left", 5, 6, 1)
    f.drag_to(9, 9, "left")
    f.button_up("left", 9, 9, 1)
    f.scroll(-3)
    assert f.kinds() == ["move", "down", "drag", "up", "scroll"]
    assert f.summary() == {"x": 9, "y": 9, "held": [], "moves": 2, "clicks": 1, "scroll": -3}


class _Quartz:
    """Just enough of Quartz to see what the backend posts and to play the system's part."""

    kCGHIDEventTap = 0
    kCGAnnotatedSessionEventTap = 2
    kCGTailAppendEventTap = 1
    kCGEventTapOptionDefault = 0
    kCGEventTapOptionListenOnly = 1
    kCGEventScrollWheel = 22
    kCGEventTapDisabledByTimeout = 0xFFFFFFFE
    kCGEventTapDisabledByUserInput = 0xFFFFFFFF
    kCGScrollEventUnitPixel = 0
    kCGScrollWheelEventIsContinuous = 88
    kCGScrollWheelEventPointDeltaAxis1 = 96
    kCGEventSourceUserData = 42
    kCFRunLoopCommonModes = "common"

    def __init__(self, allow=(kCGEventTapOptionListenOnly, kCGEventTapOptionDefault)):
        self.allow = allow            # which kinds of tap this "system" permits
        self.posted = []              # every event handed to CGEventPost
        self.callback = None
        self.enabled = []

    def CGEventMaskBit(self, kind):
        return 1 << kind

    def CGEventCreateScrollWheelEvent(self, source, unit, count, dy):
        return {"dy": dy, self.kCGScrollWheelEventPointDeltaAxis1: dy}

    def CGEventSetIntegerValueField(self, ev, field, value):
        ev[field] = value

    def CGEventGetIntegerValueField(self, ev, field):
        return ev.get(field, 0)

    def CGEventPost(self, tap, ev):
        self.posted.append(ev)

    def CGEventTapCreate(self, point, place, options, mask, callback, refcon):
        if options not in self.allow:
            return None
        self.callback = callback
        return "tap"

    def CFMachPortCreateRunLoopSource(self, allocator, tap, order):
        return "source"

    def CFRunLoopGetCurrent(self):
        return "loop"

    def CFRunLoopAddSource(self, loop, source, mode):
        pass

    def CGEventTapEnable(self, tap, on):
        self.enabled.append(on)

    def CFRunLoopRun(self):
        pass   # the real one blocks the watcher thread for good


def _arrives(q, ev, negated):
    """Play the window server: hand the tap what the application is about to get."""
    seen = dict(ev)
    seen[q.kCGScrollWheelEventPointDeltaAxis1] = -ev["dy"] if negated else ev["dy"]
    q.callback(None, q.kCGEventScrollWheel, seen, None)


def test_the_quartz_backend_notices_a_scroll_reverser_and_compensates():
    """Scroll Reverser and its kind negate every scroll event they take for a
    mouse, and ours look like a mouse. macOS's own Natural scrolling setting
    never touches a posted event, so the only way to know what the application
    received is to tag each event and watch it come out the other side."""
    q = _Quartz()
    c = QuartzCursor(quartz=q)
    assert c.scroll_watch == "listen" and c.scroll_reversed is False
    c.scroll(-15)
    assert [e["dy"] for e in q.posted] == [-15], "nothing known yet: posted as asked"
    _arrives(q, q.posted[-1], negated=True)             # a reverser flipped it
    assert c.scroll_reversed is True
    c.scroll(-15)
    assert q.posted[-1]["dy"] == 15, "pre-flipped, so the application gets -15"
    _arrives(q, q.posted[-1], negated=True)
    assert c.scroll_reversed is True, "still reversed: no oscillation"
    _arrives(q, q.posted[-1], negated=False)            # the reverser quit
    assert c.scroll_reversed is False
    c.scroll(-15)
    assert q.posted[-1]["dy"] == -15


def test_the_scroll_watch_ignores_other_devices_and_survives_being_disabled():
    q = _Quartz()
    c = QuartzCursor(quartz=q)
    c.scroll(4)
    q.callback(None, q.kCGEventScrollWheel, {q.kCGScrollWheelEventPointDeltaAxis1: -3}, None)
    assert c.scroll_reversed is False, "an untagged event is the trackpad, not ours"
    q.callback(None, q.kCGEventTapDisabledByTimeout, {}, None)
    assert q.enabled[-1] is True, "a tap the system switched off must be switched back on"


def test_a_backend_that_cannot_watch_still_scrolls():
    q = _Quartz(allow=())
    c = QuartzCursor(quartz=q)
    assert c.scroll_watch == "off"
    c.scroll(-3)
    assert q.posted[-1]["dy"] == -3


def test_a_filtering_tap_is_the_fallback_when_listening_is_refused():
    q = _Quartz(allow=(_Quartz.kCGEventTapOptionDefault,))
    c = QuartzCursor(quartz=q)
    assert c.scroll_watch == "filter"
    c.scroll(2)
    ev = dict(q.posted[-1])
    assert q.callback(None, q.kCGEventScrollWheel, ev, None) is ev, "a filter must hand it back"
    _arrives(q, q.posted[-1], negated=True)
    assert c.scroll_reversed is True
