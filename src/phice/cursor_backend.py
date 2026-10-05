"""Cursor backends: the Quartz implementation and an in-memory fake for tests and tools.

All coordinates are Quartz global points: origin at the top-left of the main
display, y grows downward.
"""
from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Literal, Protocol

log = logging.getLogger("phice.cursor")

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


#: Stamped into kCGEventSourceUserData on every scroll event we post, so the
#: watch in QuartzCursor can tell our events from the trackpad's and see which
#: way each one came out. The low bits say which sign went in.
_SCROLL_TAG = 0x5048494345 << 8      # "PHICE"
_TAG_UP, _TAG_DOWN = _SCROLL_TAG | 1, _SCROLL_TAG | 2


class QuartzCursor:
    """Posts real events through Quartz Event Services. Needs Accessibility permission.

    Scroll events are tagged and watched on their way out: a scroll reverser
    such as Scroll Reverser negates every scroll event it takes for a mouse,
    ours included, and nothing short of looking tells (see `_watch_scroll`).
    """

    def __init__(self, quartz=None) -> None:
        if quartz is None:
            import Quartz  # type: ignore[import-not-found]

            quartz = Quartz
        self._q = quartz
        self._displays_cache: list[Rect] = []
        self._displays_ts = 0.0
        #: True while our scroll events come out of the window server with the
        #: opposite sign to the one we posted; `scroll` pre-flips to match.
        self.scroll_reversed = False
        self._tap = None
        self.scroll_watch = self._watch_scroll()   # "listen", "filter" or "off"

    def _watch_scroll(self) -> str:
        """Watch our own scroll events come out of the window server.

        macOS applies Natural scrolling to real devices in the HID layer and
        leaves posted events alone. Scroll reversers (Scroll Reverser, Mos,
        LinearMouse...) sit on an event tap instead and negate everything they
        take for a mouse, which is exactly what a posted event looks like, so
        the pointer scrolled backwards on precisely the Macs whose owners had
        fixed their mouse. The only way to know what the application received
        is to look: a listen-only tap at the annotated-session level sits
        behind every reverser, and each of our events carries a tag saying
        which sign went in. A filtering tap that passes everything through is
        the fallback when the system refuses a listener: on some versions that
        needs Input Monitoring, while Accessibility, which we have anyway, is
        enough for a filter.
        """
        q = self._q
        mask = q.CGEventMaskBit(q.kCGEventScrollWheel)
        for option, name in ((q.kCGEventTapOptionListenOnly, "listen"),
                             (q.kCGEventTapOptionDefault, "filter")):
            tap = q.CGEventTapCreate(q.kCGAnnotatedSessionEventTap, q.kCGTailAppendEventTap,
                                     option, mask, self._on_scroll, None)
            if tap is not None:
                self._tap = tap
                threading.Thread(target=self._run_tap, args=(tap,),
                                 name="phice-scroll-watch", daemon=True).start()
                return name
        log.warning("cannot watch scroll events, so a scroll reverser would go unnoticed")
        return "off"

    def _run_tap(self, tap) -> None:
        q = self._q
        source = q.CFMachPortCreateRunLoopSource(None, tap, 0)
        q.CFRunLoopAddSource(q.CFRunLoopGetCurrent(), source, q.kCFRunLoopCommonModes)
        q.CGEventTapEnable(tap, True)
        q.CFRunLoopRun()

    def _on_scroll(self, proxy, kind, ev, refcon):
        q = self._q
        try:
            if kind in (q.kCGEventTapDisabledByTimeout, q.kCGEventTapDisabledByUserInput):
                q.CGEventTapEnable(self._tap, True)   # the system switches a slow tap off
            else:
                tag = q.CGEventGetIntegerValueField(ev, q.kCGEventSourceUserData)
                if tag in (_TAG_UP, _TAG_DOWN):
                    out = q.CGEventGetIntegerValueField(ev, q.kCGScrollWheelEventPointDeltaAxis1)
                    if out:
                        self.scroll_reversed = (out > 0) != (tag == _TAG_UP)
        except Exception:  # a filtering tap that raises drops the event for everyone
            log.debug("scroll watch", exc_info=True)
        return ev

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
        dy = -int(dy_px) if self.scroll_reversed else int(dy_px)
        ev = q.CGEventCreateScrollWheelEvent(None, q.kCGScrollEventUnitPixel, 1, dy)
        q.CGEventSetIntegerValueField(ev, q.kCGScrollWheelEventIsContinuous, 1)
        q.CGEventSetIntegerValueField(ev, q.kCGEventSourceUserData,
                                      _TAG_UP if dy > 0 else _TAG_DOWN)
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


def accessibility_trusted(prompt: bool = False) -> bool:
    """Whether this process may post cursor events.

    Lives here, not in the menu bar, because the runtime needs it too: the menu
    bar is optional and can fail to appear, and a status field only it updates
    is a status field that is wrong whenever it does.
    """
    try:
        from ApplicationServices import (  # type: ignore[import-not-found]
            AXIsProcessTrustedWithOptions,
            kAXTrustedCheckOptionPrompt,
        )
    except ImportError:  # pragma: no cover - only happens in a mis-built bundle
        # Do not report this as "not granted": that is indistinguishable from the
        # user simply not having approved it, and sends them to System Settings to
        # fix a packaging bug they cannot see.
        log.error("ApplicationServices is missing from this build; the Accessibility "
                  "state cannot be read. The cursor may still work.")
        return False
    try:
        return bool(AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: prompt}))
    except Exception:
        log.warning("could not query Accessibility trust", exc_info=True)
        return False
