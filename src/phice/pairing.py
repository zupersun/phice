"""Pairing tokens (short-lived, single-use) and device tokens (persistent)."""
from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

PAIR_TTL_S = 600.0
MAX_DEVICES = 16


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclass
class PairingManager:
    """Tokens live in two files so that `phice pair-token` in a terminal can
    hand a token to the already-running menu-bar process."""

    path: Path
    clock: Callable[[], float] = time.time

    @property
    def pending_path(self) -> Path:
        return self.path.with_name("pair.json")

    def mint_pairing_token(self) -> str:
        token = secrets.token_urlsafe(16)
        self._write_json(self.pending_path, {"hash": _hash(token),
                                             "expires": self.clock() + PAIR_TTL_S})
        return token

    def _pending(self) -> dict | None:
        try:
            d = json.loads(self.pending_path.read_text())
            return d if isinstance(d, dict) else None
        except (OSError, ValueError):
            return None

    def _write_json(self, path: Path, obj) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(obj, indent=2))
        tmp.replace(path)
        path.chmod(0o600)

    def _devices(self) -> list[dict]:
        try:
            data = json.loads(self.path.read_text())
            return data if isinstance(data, list) else []
        except (OSError, ValueError):
            return []

    def _save(self, devices: list[dict]) -> None:
        self._write_json(self.path, devices)

    def redeem_pairing_token(self, token: str, name: str) -> str | None:
        """Consume a pairing token and return a fresh device token, or None if invalid."""
        pending = self._pending()
        if not pending or self.clock() > float(pending.get("expires", 0)):
            return None
        if not hmac.compare_digest(_hash(token), str(pending.get("hash", ""))):
            return None
        self.pending_path.unlink(missing_ok=True)
        device_token = secrets.token_urlsafe(32)
        devices = self._devices()[-(MAX_DEVICES - 1):]
        devices.append({"hash": _hash(device_token), "name": name[:64], "created": self.clock(),
                        "last_seen": self.clock()})
        self._save(devices)
        return device_token

    def check_device_token(self, token: str) -> bool:
        h = _hash(token)
        devices = self._devices()
        found = False
        for d in devices:
            if hmac.compare_digest(str(d.get("hash", "")), h):
                d["last_seen"] = self.clock()
                found = True
        if found:
            self._save(devices)
        return found

    def revoke_all(self) -> None:
        self.pending_path.unlink(missing_ok=True)
        self._save([])

    def device_count(self) -> int:
        return len(self._devices())
