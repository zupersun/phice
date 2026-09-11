"""Cursor backends: the Quartz implementation and an in-memory fake for tests and tools.

All coordinates are Quartz global points: origin at the top-left of the main
display, y grows downward.
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Literal, Protocol

Button = Literal["left", "right"]


@dataclass(frozen=True)
class Rect:
    x: float
    y: float
    w: float
    h: float

    def contains(self, px: float, py: float) -> bool:
        return self.x <= px < self.x + self.w and self.y <= py < self.y + self.h

    def center(self) -> tuple[float, float]:
        return (self.x + self.w / 2, self.y + self.h / 2)

    def clamp(self, px: float, py: float) -> tuple[float, float]:
        return (min(max(px, self.x), self.x + self.w - 1), min(max(py, self.y), self.y + self.h - 1))


def display_containing(displays: list[Rect], x: float, y: float) -> Rect:
    """The display holding (x, y), or the nearest one if the point is outside all of them."""
    for d in displays:
        if d.contains(x, y):
            return d

    def dist2(d: Rect) -> float:
        cx, cy = d.clamp(x, y)
        return (cx - x) ** 2 + (cy - y) ** 2

    return min(displays, key=dist2)


def clamp_to_displays(displays: list[Rect], x: float, y: float, current: Rect) -> tuple[float, float]:
    """Keep a target inside any display; otherwise clamp it to the current one."""
    for d in displays:
        if d.contains(x, y):
            return (x, y)
    return current.clamp(x, y)


class CursorBackend(Protocol):
    def get_position(self) -> tuple[float, float]: ...
    def move_to(self, x: float, y: float) -> None: ...
    def drag_to(self, x: float, y: float, button: Button) -> None: ...
    def button_down(self, button: Button, x: float, y: float, click_count: int) -> None: ...
    def button_up(self, button: Button, x: float, y: float, click_count: int) -> None: ...
    def scroll(self, dy_px: int) -> None: ...
    def displays(self) -> list[Rect]: ...


@dataclass(frozen=True)
class CursorEvent:
    kind: str  # move | drag | down | up | scroll
    x: float = 0.0
    y: float = 0.0
    button: str | None = None
    count: int = 0
    dy: int = 0


@dataclass
class FakeCursor:
    """Records every call; used by unit tests, the replay tool, and `--backend fake`."""

    x: float = 100.0
    y: float = 100.0
    display_list: list[Rect] = field(default_factory=lambda: [Rect(0, 0, 1440, 900)])
    events: list[CursorEvent] = field(default_factory=list)
    held: set[str] = field(default_factory=set)

    def get_position(self) -> tuple[float, float]:
        return (self.x, self.y)

    def move_to(self, x: float, y: float) -> None:
        self.x, self.y = x, y
        self.events.append(CursorEvent("move", x, y))

    def drag_to(self, x: float, y: float, button: Button) -> None:
        self.x, self.y = x, y
        self.events.append(CursorEvent("drag", x, y, button))

    def button_down(self, button: Button, x: float, y: float, click_count: int) -> None:
        self.held.add(button)
        self.events.append(CursorEvent("down", x, y, button, click_count))

    def button_up(self, button: Button, x: float, y: float, click_count: int) -> None:
        self.held.discard(button)
        self.events.append(CursorEvent("up", x, y, button, click_count))

    def scroll(self, dy_px: int) -> None:
        self.events.append(CursorEvent("scroll", self.x, self.y, dy=dy_px))

    def displays(self) -> list[Rect]:
        return list(self.display_list)

    def kinds(self) -> list[str]:
        return [e.kind for e in self.events]

    def clear(self) -> None:
        self.events.clear()

    def summary(self) -> dict:
        return {"x": self.x, "y": self.y, "held": sorted(self.held),
                "moves": sum(1 for e in self.events if e.kind in ("move", "drag")),
                "clicks": sum(1 for e in self.events if e.kind == "down"),
                "scroll": sum(e.dy for e in self.events if e.kind == "scroll")}


class QuartzCursor:
    """Posts real events through Quartz Event Services. Needs Accessibility permission."""

    def __init__(self) -> None:
        import Quartz  # type: ignore[import-not-found]

        self._q = Quartz
        self._displays_cache: list[Rect] = []
        self._displays_ts = 0.0

    def _post(self, ev) -> None:
        self._q.CGEventPost(self._q.kCGHIDEventTap, ev)

    def _btn(self, button: Button):
        return self._q.kCGMouseButtonLeft if button == "left" else self._q.kCGMouseButtonRight

    def get_position(self) -> tuple[float, float]:
        p = self._q.CGEventGetLocation(self._q.CGEventCreate(None))
        return (float(p.x), float(p.y))

    def move_to(self, x: float, y: float) -> None:
        q = self._q
        self._post(q.CGEventCreateMouseEvent(None, q.kCGEventMouseMoved, (x, y), q.kCGMouseButtonLeft))

    def drag_to(self, x: float, y: float, button: Button) -> None:
        q = self._q
        kind = q.kCGEventLeftMouseDragged if button == "left" else q.kCGEventRightMouseDragged
        self._post(q.CGEventCreateMouseEvent(None, kind, (x, y), self._btn(button)))

    def button_down(self, button: Button, x: float, y: float, click_count: int) -> None:
        q = self._q
        kind = q.kCGEventLeftMouseDown if button == "left" else q.kCGEventRightMouseDown
        ev = q.CGEventCreateMouseEvent(None, kind, (x, y), self._btn(button))
        q.CGEventSetIntegerValueField(ev, q.kCGMouseEventClickState, click_count)
        self._post(ev)

    def button_up(self, button: Button, x: float, y: float, click_count: int) -> None:
        q = self._q
        kind = q.kCGEventLeftMouseUp if button == "left" else q.kCGEventRightMouseUp
        ev = q.CGEventCreateMouseEvent(None, kind, (x, y), self._btn(button))
        q.CGEventSetIntegerValueField(ev, q.kCGMouseEventClickState, click_count)
        self._post(ev)

    def scroll(self, dy_px: int) -> None:
        q = self._q
        ev = q.CGEventCreateScrollWheelEvent(None, q.kCGScrollEventUnitPixel, 1, int(dy_px))
        q.CGEventSetIntegerValueField(ev, q.kCGScrollWheelEventIsContinuous, 1)
        self._post(ev)

    def displays(self) -> list[Rect]:
        now = time.monotonic()
        if now - self._displays_ts > 2.0 or not self._displays_cache:
            q = self._q
            err, ids, count = q.CGGetActiveDisplayList(16, None, None)
            rects = []
            if err == 0:
                for did in list(ids)[:count]:
                    b = q.CGDisplayBounds(did)
                    rects.append(Rect(b.origin.x, b.origin.y, b.size.width, b.size.height))
            self._displays_cache = rects or [Rect(0, 0, 1440, 900)]
            self._displays_ts = now
        return list(self._displays_cache)
