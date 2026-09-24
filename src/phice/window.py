"""Native windows hosting the Mac-side pages.

They are HTML in a WKWebView rather than native widgets, for the same reason the
phone UI is: the design lives in a CSS file the user owns and can restyle,
instead of being compiled into the app. The window is only a frame around it.

Closing a window does not quit anything -- the app is LSUIElement, so it keeps
running in the menu bar, and opening Phice again brings the panel back.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass

log = logging.getLogger("phice.window")


@dataclass
class Requests:
    """Window requests raised on the runtime thread and honoured on the main one.

    A window can only be created where AppKit lives, on the thread the menu bar
    owns, so the runtime never opens one itself: it leaves a note here and the
    menu bar's timer takes it. Each note is taken exactly once.
    """

    _panel: bool = False                     # the control panel, or the page below
    _page: tuple[str, bool] | None = None    # (url, fullscreen) for a specific page
    _close_calibration: bool = False

    def show_panel(self) -> None:
        self._panel = True

    def show(self, url: str, *, fullscreen: bool = False) -> None:
        self._page = (url, fullscreen)
        self._panel = True

    def close_calibration(self) -> None:
        self._close_calibration = True

    def take_panel(self) -> tuple[str, bool] | bool:
        """(url, fullscreen) to open, True for the control panel, or False."""
        if not self._panel:
            return False
        self._panel = False
        page, self._page = self._page, None
        return page or True

    def take_calibration_close(self) -> bool:
        done, self._close_calibration = self._close_calibration, False
        return done

#: Built once, on first use: an Objective-C class cannot be defined twice under
#: the same name, and AppKit is only imported inside the functions below.
_fullscreen_class = None


def _fullscreen_window(AppKit):
    """An NSWindow that does not let AppKit move it off the menu bar.

    Every ordinary route -- setFrame:display:, setFrameOrigin: -- runs the rect
    through constrainFrameRect:toScreen:, which pushes the window clear of the
    menu bar. The result was a window 32px low, hanging off the bottom of the
    display with a strip of desktop above it, and calibration cannot live with
    that: it maps page coordinates directly onto display coordinates.
    """
    global _fullscreen_class
    if _fullscreen_class is None:
        class PhiceFullScreenWindow(AppKit.NSWindow):
            def constrainFrameRect_toScreen_(self, rect, screen):
                return rect

        _fullscreen_class = PhiceFullScreenWindow
    return _fullscreen_class


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
                # Titled with a full-size content view, NOT borderless. A
                # borderless window cannot become the key window, so it never
                # receives a key press -- Escape did nothing and there was no way
                # out of a window covering the whole screen. FullSizeContentView
                # keeps the content rect equal to the frame, which calibration
                # depends on: page coordinates have to be display coordinates.
                style = (AppKit.NSWindowStyleMaskTitled
                         | AppKit.NSWindowStyleMaskClosable
                         | AppKit.NSWindowStyleMaskFullSizeContentView)
            else:
                rect = AppKit.NSMakeRect(0, 0, 420, 620)
                style = (AppKit.NSWindowStyleMaskTitled
                         | AppKit.NSWindowStyleMaskClosable
                         | AppKit.NSWindowStyleMaskMiniaturizable
                         | AppKit.NSWindowStyleMaskResizable)
            cls = _fullscreen_window(AppKit) if fullscreen else AppKit.NSWindow
            win = cls.alloc().initWithContentRect_styleMask_backing_defer_(
                rect, style, AppKit.NSBackingStoreBuffered, False)
            win.setTitle_(title)
            win.setReleasedWhenClosed_(False)   # reuse it; do not free on close
            if fullscreen:
                win.setTitlebarAppearsTransparent_(True)
                win.setTitleVisibility_(AppKit.NSWindowTitleHidden)
                win.setMovable_(False)          # dragging it would break the mapping
                # Above the Dock (20) and the menu bar (24). At a lower level the
                # Dock draws over the window, and AppKit also refuses to let an
                # ordinary window cover the menu bar -- so the frame came back
                # shortened and the desktop showed through the gap.
                win.setLevel_(AppKit.NSStatusWindowLevel)
                win.setCollectionBehavior_(
                    AppKit.NSWindowCollectionBehaviorFullScreenAuxiliary
                    | AppKit.NSWindowCollectionBehaviorCanJoinAllSpaces)
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
        if fullscreen:
            # Take the Dock and the menu bar off the screen for the duration.
            # Raising the window above them is not enough on its own: the Dock
            # still slides out on hover, over the top of whatever is showing.
            AppKit.NSApp.setPresentationOptions_(
                AppKit.NSApplicationPresentationHideDock
                | AppKit.NSApplicationPresentationHideMenuBar)
            win.setFrame_display_(AppKit.NSScreen.mainScreen().frame(), True)
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
        import AppKit
        entry[0].orderOut_(None)
        # Give the Dock and the menu bar back. Leaving them hidden after the
        # window has gone would look like the Mac itself had broken.
        AppKit.NSApp.setPresentationOptions_(AppKit.NSApplicationPresentationDefault)
    except Exception:
        log.exception("could not close the %s window", key)
