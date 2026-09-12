"""Filesystem layout of the config directory and packaged resources."""
from __future__ import annotations

import os
import shutil
import sys
import time
from dataclasses import dataclass
from pathlib import Path

APP_NAME = "Phice"


def resource_dir() -> Path:
    """Directory holding packaged defaults/ and web/.

    PyInstaller unpacks data files to sys._MEIPASS rather than leaving them
    beside __file__, so the frozen bundle must be asked where they went.
    """
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS)  # type: ignore[attr-defined]
    return Path(__file__).resolve().parent


PACKAGE_DIR = resource_dir()
DEFAULTS_DIR = PACKAGE_DIR / "defaults"
WEB_DIR = PACKAGE_DIR / "web"
UI_FILES = ("layout.json", "theme.css", "panel.css")


def default_config_dir() -> Path:
    env = os.environ.get("PHICE_CONFIG_DIR")
    if env:
        return Path(env).expanduser()
    return Path.home() / "Library" / "Application Support" / APP_NAME


@dataclass(frozen=True)
class Paths:
    root: Path

    @property
    def pointer_json(self) -> Path: return self.root / "pointer.json"
    @property
    def layout_json(self) -> Path: return self.root / "layout.json"
    @property
    def theme_css(self) -> Path: return self.root / "theme.css"
    @property
    def panel_css(self) -> Path: return self.root / "panel.css"
    @property
    def assets(self) -> Path: return self.root / "assets"
    @property
    def devices_json(self) -> Path: return self.root / "devices.json"
    @property
    def certs(self) -> Path: return self.root / "certs"
    @property
    def logs(self) -> Path: return self.root / "logs"
    @property
    def sessions(self) -> Path: return self.root / "sessions"

    def ensure(self) -> None:
        """Create directories and copy packaged defaults for anything missing."""
        for d in (self.root, self.certs, self.logs, self.sessions):
            d.mkdir(parents=True, exist_ok=True)
        for name in ("pointer.json", *UI_FILES):
            dst = self.root / name
            if not dst.exists():
                shutil.copy(DEFAULTS_DIR / name, dst)
        if not self.assets.exists():
            shutil.copytree(DEFAULTS_DIR / "assets", self.assets)
        from .icons import write_defaults
        write_defaults(self.assets)

    def reset_ui(self) -> list[Path]:
        """Restore layout/theme/assets from package defaults, backing up existing files."""
        stamp = time.strftime("%Y%m%d-%H%M%S")
        backed_up: list[Path] = []
        for name in UI_FILES:
            dst = self.root / name
            if dst.exists():
                bak = dst.with_name(f"{name}.{stamp}.bak")
                dst.rename(bak)
                backed_up.append(bak)
            shutil.copy(DEFAULTS_DIR / name, dst)
        if self.assets.exists():
            bak = self.assets.with_name(f"assets.{stamp}.bak")
            self.assets.rename(bak)
            backed_up.append(bak)
        shutil.copytree(DEFAULTS_DIR / "assets", self.assets)
        from .icons import write_defaults
        write_defaults(self.assets)
        return backed_up
