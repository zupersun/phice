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
ACCESSIBILITY_PANE = ("x-apple.systempreferences:com.apple.preference.security"
                      "?Privacy_Accessibility")


def accessibility_trusted(prompt: bool = False) -> bool:
    ok = _trusted(prompt)
    if not ok and prompt:
        log.info("prompted for Accessibility")
    return ok


class PhiceApp(rumps.App):
    def __init__(self, runtime: Runtime):
        super().__init__("Phice", quit_button=None)
        self.runtime = runtime
        self.paths: Paths = runtime.paths
        self._icon_state = ""

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
            rumps.MenuItem("Show setup page…", callback=self.show_setup),
            self.item_enabled,
            rumps.MenuItem("Reload config now", callback=self.reload_config),
            rumps.MenuItem("Open config folder", callback=self.open_config),
            self.item_record,
            None,
            rumps.MenuItem("Grant Accessibility…", callback=self.grant_accessibility),
            self.item_login,
            rumps.MenuItem("Revoke all paired devices", callback=self.revoke),
            None,
            rumps.MenuItem("Quit Phice", callback=self.quit),
        ]
        self._timer = rumps.Timer(self.refresh, 1)
        self._timer.start()
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

    def show_setup(self, _):
        webbrowser.open(f"http://127.0.0.1:{self.runtime.http_port}/setup")

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

    def revoke(self, _):
        self.runtime.revoke_devices()
        rumps.notification("Phice", "Paired devices revoked", "Scan the pairing QR again.")

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
            self.title = {"warn": "Phice!", "disconnected": "Phice",
                          "off": "Phice\u00b7", "on": "Phice\u25cf"}[name]

    def refresh(self, _):
        self._ticks += 1
        if self.runtime.take_calibration_close():
            window.close("calibrate")
        wanted = self.runtime.take_panel_request()
        if wanted is True:
            self.show_panel()
        elif wanted:
            url, fullscreen = wanted
            window.open_panel(url, key="calibrate" if fullscreen else "panel",
                              fullscreen=fullscreen)
        if self._ticks == 2:
            # Every launch, not just the first: the menu bar icon can be
            # invisible behind the notch, and then there is nothing to click.
            # The pairing code changes each launch anyway, so the window is
            # what the user needs to see.
            self.show_panel()
        if self._ticks % 3 == 1:
            self.runtime.set_accessibility(accessibility_trusted())
        s = self.runtime.status.read()
        if not s["accessibility"]:
            self._set_icon("warn")
            label = "Accessibility permission needed"
        elif not s["connected"]:
            self._set_icon("disconnected")
            label = "No phone connected"
        elif s["phase"] in ("on", "hold", "held"):
            self._set_icon("on")
            label = f"{s['device_name'] or 'Phone'} · pointer ON"
        else:
            self._set_icon("off")
            label = f"{s['device_name'] or 'Phone'} · pointer off"
        if s["error"]:
            label = f"Config error: {s['error'][:48]}"
        self.item_status.title = label


def run_menubar(runtime: Runtime) -> int:
    runtime.start_background()
    PhiceApp(runtime).run()
    return 0
