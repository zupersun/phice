"""Where the app writes its log, and the status snapshot the menu bar and the
debug hook read. Held apart from runtime.py only for length."""
from __future__ import annotations

import logging
import logging.handlers
import threading
from dataclasses import dataclass, field

from .paths import Paths


def setup_logging(paths: Paths, debug: bool = False) -> None:
    paths.logs.mkdir(parents=True, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(paths.logs / "phice.log", maxBytes=1 << 20,
                                                   backupCount=3)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    root = logging.getLogger()
    root.handlers = [handler, logging.StreamHandler()]
    root.setLevel(logging.DEBUG if debug else logging.INFO)


@dataclass
class Status:
    """Thread-safe snapshot the menu bar and the panel read once a second."""

    lock: threading.Lock = field(default_factory=threading.Lock)
    connected: bool = False
    device_name: str = ""
    phase: str = "disconnected"
    accessibility: bool = False
    pair_code: str = ""
    enabled: bool = True
    error: str = ""
    #: Set while the letterbox cannot be reached. Separate from `error`, which is
    #: about the config files: the panel and the menu bar say different things.
    pairing_error: str = ""

    def read(self) -> dict:
        with self.lock:
            return dict(connected=self.connected, device_name=self.device_name, phase=self.phase,
                        accessibility=self.accessibility, enabled=self.enabled,
                        pair_code=self.pair_code, error=self.error,
                        pairing_error=self.pairing_error)

    def update(self, **kw) -> None:
        with self.lock:
            for k, v in kw.items():
                setattr(self, k, v)
