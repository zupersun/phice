"""Native windows hosting the Mac-side pages.

They are HTML in a WKWebView rather than native widgets, for the same reason the
phone UI is: the design lives in a CSS file the user owns and can restyle,
instead of being compiled into the app. The window is only a frame around it.

Closing a window does not quit anything -- the app is LSUIElement, so it keeps
running in the menu bar, and opening Phice again brings the panel back.
"""
from __future__ import annotations

import logging

log = logging.getLogger("phice.window")

#: Kept alive by key: a released NSWindow closes itself. The panel and the
#: calibration screen are separate windows because they are different shapes --
#: resizing one into the other would leave the panel full screen afterwards.
_windows: dict[str, tuple] = {}


def open_panel(url: str, title: str = "Phice", *, key: str = "panel",
               fullscreen: bool = False) -> bool:
    """Show a window, creating it once per key and reusing it thereafter.

    `fullscreen` gives a borderless window covering the whole display. The
    calibration screen needs that exactly, not approximately: it positions
    targets as fractions of the display, and the Mac scores them against the
    real cursor position in display coordinates. In a smaller window the dot on
    screen and the target the engine is scoring would be in different places,
    and every measurement would be wrong by the difference.
    """
    try:
        import AppKit
        import WebKit
        from Foundation import NSURL, NSURLRequest
    except Exception:
        log.warning("WebKit unavailable; cannot open a window", exc_info=True)
        return False

    try:
        existing = _windows.get(key)
        if existing is None:
            screen = AppKit.NSScreen.mainScreen()
            if fullscreen and screen is not None:
                rect = screen.frame()          # frame, not visibleFrame: cover the menu bar too
                style = AppKit.NSWindowStyleMaskBorderless
            else:
                rect = AppKit.NSMakeRect(0, 0, 420, 620)
                style = (AppKit.NSWindowStyleMaskTitled
                         | AppKit.NSWindowStyleMaskClosable
                         | AppKit.NSWindowStyleMaskMiniaturizable
                         | AppKit.NSWindowStyleMaskResizable)
            win = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
                rect, style, AppKit.NSBackingStoreBuffered, False)
            win.setTitle_(title)
            win.setReleasedWhenClosed_(False)   # reuse it; do not free on close
            if fullscreen:
                win.setLevel_(AppKit.NSFloatingWindowLevel)
                win.setFrame_display_(rect, True)
            else:
                win.center()
            view = WebKit.WKWebView.alloc().initWithFrame_(rect)
            view.setAutoresizingMask_(AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
            win.setContentView_(view)
            _windows[key] = (win, view)

        win, view = _windows[key]
        view.loadRequest_(NSURLRequest.requestWithURL_(NSURL.URLWithString_(url)))
        AppKit.NSApp.activateIgnoringOtherApps_(True)
        win.makeKeyAndOrderFront_(None)
        return True
    except Exception:
        log.exception("could not open the %s window", key)
        return False


def close(key: str) -> None:
    """Close one window without disturbing the other."""
    entry = _windows.get(key)
    if entry is None:
        return
    try:
        entry[0].orderOut_(None)
    except Exception:
        log.exception("could not close the %s window", key)
