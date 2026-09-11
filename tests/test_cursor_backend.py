from phice.cursor_backend import FakeCursor, Rect, clamp_to_displays, display_containing

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
