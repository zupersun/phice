"""A native window hosting the control panel.

The panel is HTML served on loopback rather than native widgets, for the same
reason the phone UI is: the design lives in a CSS file the user owns and can
restyle, instead of being compiled into the app. The window is only a frame
around it.

Closing the window does not quit anything -- the app is LSUIElement, so it keeps
running in the menu bar.
"""
from __future__ import annotations

import logging

log = logging.getLogger("phice.window")

_window = None  # kept alive: a released NSWindow closes itself


def open_panel(url: str, title: str = "Phice") -> bool:
    """Show the panel window, creating it once and reusing it thereafter."""
    global _window
    try:
        import AppKit
        import WebKit
        from Foundation import NSURL, NSURLRequest
    except Exception:
        log.warning("WebKit unavailable; cannot open the panel window", exc_info=True)
        return False

    try:
        if _window is None:
            rect = AppKit.NSMakeRect(0, 0, 420, 560)
            style = (AppKit.NSWindowStyleMaskTitled
                     | AppKit.NSWindowStyleMaskClosable
                     | AppKit.NSWindowStyleMaskMiniaturizable
                     | AppKit.NSWindowStyleMaskResizable)
            win = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
                rect, style, AppKit.NSBackingStoreBuffered, False)
            win.setTitle_(title)
            win.setReleasedWhenClosed_(False)   # reuse it; do not free on close
            win.center()
            view = WebKit.WKWebView.alloc().initWithFrame_(rect)
            view.setAutoresizingMask_(AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
            win.setContentView_(view)
            _window = (win, view)

        win, view = _window
        view.loadRequest_(NSURLRequest.requestWithURL_(NSURL.URLWithString_(url)))
        AppKit.NSApp.activateIgnoringOtherApps_(True)
        win.makeKeyAndOrderFront_(None)
        return True
    except Exception:
        log.exception("could not open the panel window")
        return False
