"""Menu bar UI. Owns the main thread; the runtime's asyncio loop runs beside it."""
from __future__ import annotations

import logging
import subprocess
import webbrowser

import rumps

from . import window
from .cli import agent_plist_path
from .cursor_backend import accessibility_trusted as _trusted
from .paths import Paths
from .runtime import Runtime

log = logging.getLogger("phice.menubar")

ICONS = {"warn": "menubar/warn.png", "disconnected": "menubar/disconnected.png",
         "off": "menubar/off.png", "on": "menubar/on.png"}
TITLES = {"warn": "Phice!", "disconnected": "Phice", "off": "Phice·", "on": "Phice●"}
ACCESSIBILITY_PANE = ("x-apple.systempreferences:com.apple.preference.security"
                      "?Privacy_Accessibility")

#: What macOS sends the instance that is already running when Phice is launched again.
REOPEN_SEL = "applicationShouldHandleReopen:hasVisibleWindows:"


def install_reopen_handler(show, cls=None) -> bool:
    """Make launching Phice again bring its window back.

    Opening an app that is already running starts no second process: macOS
    activates the one that is running and sends its delegate this message. The
    delegate rumps installs does not implement it, so every launch after the
    first did nothing at all -- the Dock icon, Spotlight, Launchpad and `open -a`
    alike -- which left a running Phice whose window had been closed with no way
    back except a menu bar icon the notch can swallow on a full bar.

    The method goes onto rumps' delegate class rather than a subclass, because
    rumps builds that instance and hands it to AppKit itself. `cls` lets a test
    prove the mechanism against a throwaway class instead of the real one.
    """
    import objc

    if cls is None:
        from rumps.rumps import NSApp as cls  # noqa: N813 - rumps' delegate class
    if cls.instancesRespondToSelector_(REOPEN_SEL):
        return True            # already on; adding a selector twice raises

    def _reopen(self, app, has_visible_windows) -> bool:
        # Only asked for here. The window is made by the menu bar's pump, which
        # already owns the AppKit thread, so there is one path to a window and
        # nothing to race. Asking while a window is up is harmless: the request
        # is a one-shot mailbox and reopening brings it to the active space.
        try:
            log.info("launched again (windows visible: %s); asking for the panel",
                     bool(has_visible_windows))
            show()
        except Exception:
            log.warning("could not ask for the window on reopen", exc_info=True)
        return True

    try:
        # BOOL (self, _cmd, NSApplication *, BOOL)
        objc.classAddMethods(cls, [objc.selector(_reopen, selector=REOPEN_SEL.encode(),
                                                 signature=b"B@:@B")])
    except Exception:
        log.warning("no reopen handler; launching Phice again will not reopen the "
                    "window", exc_info=True)
        return False
    return True


def accessibility_trusted(prompt: bool = False) -> bool:
    ok = _trusted(prompt)
    if not ok and prompt:
        log.info("prompted for Accessibility")
    return ok


def describe(s: dict) -> tuple[str, str]:
    """Icon name and status line for a status snapshot, most urgent first.

    Pure, so the ordering is pinned by a test rather than by looking at the
    menu bar, which may be invisible behind the notch. A working pointer
    outranks a letterbox error: once connected, the Mac no longer needs the
    pairing service, so a stale `pairing_error` must not claim breakage.
    """
    if not s["accessibility"]:
        return "warn", "Accessibility permission needed"
    if s["connected"]:
        name = s["device_name"] or "Phone"
        if s["phase"] in ("on", "hold", "held"):
            return "on", f"{name} · pointer ON"
        return "off", f"{name} · pointer off"
    if s["pairing_error"]:
        return "warn", "Can't reach the pairing service"
    return "disconnected", "No phone connected"


class PhiceApp(rumps.App):
    def __init__(self, runtime: Runtime):
        super().__init__("Phice", quit_button=None)
        self.runtime = runtime
        self.paths: Paths = runtime.paths
        self._icon_state = ""
        # Clicking the Dock icon, or launching Phice any other way, must bring
        # the window back rather than doing nothing.
        install_reopen_handler(runtime.windows.show_panel)

        self.item_status = rumps.MenuItem("Starting…")
        self.item_status.set_callback(None)
        self.item_enabled = rumps.MenuItem("Pointer enabled", callback=self.toggle_enabled)
        self.item_enabled.state = True
        self.item_record = rumps.MenuItem("Record session", callback=self.toggle_record)
        self.item_login = rumps.MenuItem("Launch at login", callback=self.toggle_login)
        self.item_login.state = agent_plist_path().exists()

        self.menu = [
            self.item_status,
            None,
            rumps.MenuItem("Open Phice window", callback=self.show_panel),
            rumps.MenuItem("Calibrate pointer…", callback=self.calibrate),
            rumps.MenuItem("Stop calibrating", callback=self.stop_calibrating),
            self.item_enabled,
            rumps.MenuItem("Reload config now", callback=self.reload_config),
            rumps.MenuItem("Open config folder", callback=self.open_config),
            self.item_record,
            None,
            rumps.MenuItem("Grant Accessibility…", callback=self.grant_accessibility),
            self.item_login,
            rumps.MenuItem("New pairing code", callback=self.new_code),
            None,
            rumps.MenuItem("Quit Phice", callback=self.quit),
        ]
        self._timer = rumps.Timer(self.refresh, 1)
        self._timer.start()
        # Windows are asked for from the runtime thread and can only be created
        # on this one. A second-long wait to honour a click reads as a dead
        # button, so check for those requests far more often than the status.
        self._windows = rumps.Timer(self.pump_windows, 0.15)
        self._windows.start()
        self._ticks = 0

    # ----- menu actions -----------------------------------------------------

    def panel_url(self) -> str:
        return f"http://127.0.0.1:{self.runtime.http_port}/panel"

    def show_panel(self, _=None):
        # Falls back to the browser rather than failing silently: on a Mac where
        # WebKit will not load, the panel is still the only place the code lives.
        if not window.open_panel(self.panel_url()):
            webbrowser.open(self.panel_url())

    def calibrate(self, _):
        self.runtime.start_calibration()

    def stop_calibrating(self, _):
        """A way out that does not depend on the calibration window itself.

        It covers the whole display, so if anything about it goes wrong there
        has to be an exit somewhere else."""
        self.runtime.cancel_calibration()

    def toggle_enabled(self, sender):
        sender.state = not sender.state
        self.runtime.set_enabled(bool(sender.state))

    def reload_config(self, _):
        self.runtime.force_reload()

    def open_config(self, _):
        subprocess.run(["open", str(self.paths.root)], check=False)

    def toggle_record(self, sender):
        sender.state = not sender.state
        path = self.runtime.set_recording(bool(sender.state))
        if path:
            rumps.notification("Phice", "Recording", str(path))

    def grant_accessibility(self, _):
        accessibility_trusted(prompt=True)
        subprocess.run(["open", ACCESSIBILITY_PANE], check=False)

    def toggle_login(self, sender):
        sender.state = not sender.state
        if sender.state:
            from .cli import cmd_install
            cmd_install(type("A", (), {"config_dir": str(self.paths.root)}))
        else:
            agent_plist_path().unlink(missing_ok=True)

    def new_code(self, _):
        """Drop the phone that is connected, if any, and publish a fresh code."""
        self.runtime.new_pair_code()
        self.show_panel()

    def quit(self, _):
        self.runtime.stop()
        rumps.quit_application()

    # ----- periodic refresh -------------------------------------------------

    def _set_icon(self, name: str) -> None:
        if name == self._icon_state:
            return
        self._icon_state = name
        path = self.paths.assets / ICONS[name]
        if path.exists():
            self.icon = str(path)
            self.template = True
            self.title = None
        else:
            self.icon = None
            self.title = TITLES[name]

    def pump_windows(self, _):
        if self.runtime.windows.take_calibration_close():
            window.close("calibrate")
        wanted = self.runtime.windows.take_panel()
        if wanted is True:
            self.show_panel()
        elif wanted:
            url, fullscreen = wanted
            window.open_panel(url, key="calibrate" if fullscreen else "panel",
                              fullscreen=fullscreen)
        height = self.runtime.windows.take_panel_height()
        if height:
            window.resize_panel(height)

    def refresh(self, _):
        self._ticks += 1
        if self._ticks == 2:
            # Every launch, not just the first: the menu bar icon can be
            # invisible behind the notch, and then there is nothing to click.
            # The pairing code changes each launch anyway, so the window is
            # what the user needs to see.
            self.show_panel()
        s = self.runtime.status.read()
        icon, label = describe(s)
        self._set_icon(icon)
        if s["error"]:
            label = f"Config error: {s['error'][:48]}"
        self.item_status.title = label


def run_menubar(runtime: Runtime) -> int:
    runtime.start_background()
    PhiceApp(runtime).run()
    return 0
