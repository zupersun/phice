"""Pointer tuning (pointer.json) and phone layout (layout.json): parsing, validation, watching."""
from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

APPEARANCES = ("dark", "light")
ROLES = frozenset({"left", "right", "scroll", "power", "clutch", "recenter"})
SINGLETON_ROLES = frozenset({"left", "right", "scroll", "power"})
BUTTON_ID_RE = re.compile(r"^[a-z0-9_-]{1,32}$")


class ConfigError(ValueError):
    pass


def _num(d: dict, key: str, default: float, lo: float, hi: float) -> float:
    v = d.get(key, default)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise ConfigError(f"{key}: expected a number")
    if not (lo <= v <= hi):
        raise ConfigError(f"{key}: must be between {lo} and {hi}")
    return float(v)


def _int(d: dict, key: str, default: int, lo: int, hi: int) -> int:
    return int(_num(d, key, default, lo, hi))


def _bool(d: dict, key: str, default: bool) -> bool:
    v = d.get(key, default)
    if not isinstance(v, bool):
        raise ConfigError(f"{key}: expected true/false")
    return v


def _sub(d: dict, key: str) -> dict:
    v = d.get(key, {})
    if not isinstance(v, dict):
        raise ConfigError(f"{key}: expected an object")
    return v


@dataclass(frozen=True)
class OneEuroConfig:
    #: Tuned the standard way: min_cutoff low enough that a held-still hand
    #: does not shake the cursor, beta high enough that deliberate movement
    #: is not laggy. The previous 1.0/0.02 was both at once -- jitter passed
    #: through at rest and real movement was over-smoothed.
    min_cutoff: float = 0.4
    beta: float = 0.12
    d_cutoff: float = 1.0


@dataclass(frozen=True)
class AccelConfig:
    enabled: bool = False
    threshold_dps: float = 40.0
    k: float = 0.01
    max_mult: float = 3.0


@dataclass(frozen=True)
class UIConfig:
    haptics: bool = True
    keep_awake: str = "always"
    #: "dark" | "light". Chosen on the Mac and pushed to the phone, so both
    #: surfaces match without the phone needing a setting of its own.
    appearance: str = "dark"
    #: Which preset in layouts/ is active, by filename stem. Empty means use
    #: layout.json, which is what every install before this had.
    layout: str = ""


@dataclass(frozen=True)
class PointerConfig:
    version: int = 1
    gain_x_px_per_deg: float = 18.0
    gain_y_px_per_deg: float = 18.0
    invert_y: bool = False
    mapping: str = "absolute"
    expo: float = 1.2
    expo_ref_deg: float = 18.0
    expo_max: float = 4.0
    edge_slack_px: float = 24.0
    one_euro: OneEuroConfig = field(default_factory=OneEuroConfig)
    deadzone_dps: float = 0.0
    accel: AccelConfig = field(default_factory=AccelConfig)
    freeze_ms_on_touch: int = 120
    freeze_ms_on_release: int = 60
    chord_window_ms: int = 50
    recenter_hold_ms: int = 650
    #: Snap the cursor to the middle of the display when the pointer is
    #: switched on, so it always starts from a known place.
    recenter_on_power_on: bool = True
    double_click_s: float = 0.5
    #: Displacement scrolling from the raw touch delta. Off by default: the strip
    #: is a rate control, and adding displacement on top of it reads as doubled.
    scroll_gain: float = 0.0
    scroll_natural: bool = False
    #: The strip scrolls at a rate set by how far the finger is from its centre:
    #: a dead band in the middle so resting a finger does nothing, then speed
    #: rising to scroll_rate_px_per_s at the ends. Raise the exponent for a
    #: gentler middle, lower it for a more linear feel.
    scroll_deadzone: float = 0.035
    #: Any deflection past the dead band scrolls at least this fast, so nudging
    #: the thumb off centre does something visible instead of nothing.
    scroll_min_px_per_s: float = 90.0
    scroll_rate_px_per_s: float = 2400.0
    scroll_rate_expo: float = 1.7
    auto_activate: bool = False
    wake_on_any_button: bool = True
    auto_deactivate: bool = True
    pickup_ms: int = 300
    rest_seconds: float = 2.5
    rest_tilt_deg: float = 15.0
    rest_rate_dps: float = 8.0
    idle_hz_when_auto_activate: int = 10
    timeout_ms: int = 500
    cert_mode: str = "auto"
    tailscale_host: str = ""
    transport: str = "tls"
    signaling_url: str = "https://phice.vercel.app"
    ice_servers: tuple = ()
    ui: UIConfig = field(default_factory=UIConfig)

    @property
    def idle_hz(self) -> int:
        return self.idle_hz_when_auto_activate if self.auto_activate else 0

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: Any) -> PointerConfig:
        if not isinstance(d, dict):
            raise ConfigError("pointer.json must contain an object")
        oe = _sub(d, "one_euro")
        ac = _sub(d, "accel")
        ui = _sub(d, "ui")
        keep_awake = ui.get("keep_awake", "always")
        if keep_awake not in ("always", "on_only"):
            raise ConfigError("ui.keep_awake: expected 'always' or 'on_only'")
        layout_name = ui.get("layout", "")
        if not isinstance(layout_name, str) or "/" in layout_name or ".." in layout_name:
            raise ConfigError("ui.layout: expected a plain preset name")
        appearance = ui.get("appearance", "dark")
        if appearance == "system":
            appearance = "dark"   # the setting was dropped; do not reject old config
        if appearance not in APPEARANCES:
            raise ConfigError(f"ui.appearance: expected one of {', '.join(APPEARANCES)}")
        cert_mode = d.get("cert_mode", "auto")
        if cert_mode not in ("auto", "external", "tailscale"):
            raise ConfigError("cert_mode: expected 'auto', 'external' or 'tailscale'")
        ts_host = d.get("tailscale_host", "")
        if not isinstance(ts_host, str) or len(ts_host) > 253:
            raise ConfigError("tailscale_host: expected a hostname")
        mapping = d.get("mapping", "absolute")
        if mapping not in ("absolute", "relative"):
            raise ConfigError("mapping: expected 'absolute' or 'relative'")
        transport = d.get("transport", "tls")
        if transport not in ("tls", "webrtc"):
            raise ConfigError("transport: expected 'tls' or 'webrtc'")
        raw_ice = d.get("ice_servers", [])
        if not isinstance(raw_ice, list) or len(raw_ice) > 8:
            raise ConfigError("ice_servers: expected a list of at most 8 entries")
        ice: list[dict] = []
        for i, s in enumerate(raw_ice):
            if not isinstance(s, dict) or not isinstance(s.get("urls"), str):
                raise ConfigError(f"ice_servers[{i}]: expected an object with a urls string")
            entry = {"urls": s["urls"]}
            for k in ("username", "credential"):
                if s.get(k) is not None:
                    if not isinstance(s[k], str):
                        raise ConfigError(f"ice_servers[{i}].{k}: expected a string")
                    entry[k] = s[k]
            ice.append(entry)
        signaling_url = d.get("signaling_url", "https://phice.vercel.app")
        if not isinstance(signaling_url, str) or not signaling_url.startswith("https://"):
            # Plain HTTP signaling would let anyone on the path swap the offer and
            # take over the pairing.
            raise ConfigError("signaling_url: expected an https:// URL")
        return cls(
            version=_int(d, "version", 1, 1, 1),
            gain_x_px_per_deg=_num(d, "gain_x_px_per_deg", 18.0, 0.1, 500.0),
            gain_y_px_per_deg=_num(d, "gain_y_px_per_deg", 18.0, 0.1, 500.0),
            invert_y=_bool(d, "invert_y", False),
            mapping=mapping,
            expo=_num(d, "expo", 1.2, 0.0, 10.0),
            expo_ref_deg=_num(d, "expo_ref_deg", 18.0, 1.0, 90.0),
            expo_max=_num(d, "expo_max", 4.0, 1.0, 20.0),
            edge_slack_px=_num(d, "edge_slack_px", 24.0, 0.0, 2000.0),
            one_euro=OneEuroConfig(
                min_cutoff=_num(oe, "min_cutoff", 0.4, 0.01, 100.0),
                beta=_num(oe, "beta", 0.12, 0.0, 10.0),
                d_cutoff=_num(oe, "d_cutoff", 1.0, 0.01, 100.0),
            ),
            deadzone_dps=_num(d, "deadzone_dps", 0.0, 0.0, 90.0),
            accel=AccelConfig(
                enabled=_bool(ac, "enabled", False),
                threshold_dps=_num(ac, "threshold_dps", 40.0, 0.0, 1000.0),
                k=_num(ac, "k", 0.01, 0.0, 1.0),
                max_mult=_num(ac, "max_mult", 3.0, 1.0, 20.0),
            ),
            freeze_ms_on_touch=_int(d, "freeze_ms_on_touch", 120, 0, 2000),
            freeze_ms_on_release=_int(d, "freeze_ms_on_release", 60, 0, 2000),
            chord_window_ms=_int(d, "chord_window_ms", 50, 0, 500),
            recenter_hold_ms=_int(d, "recenter_hold_ms", 650, 100, 10000),
            recenter_on_power_on=_bool(d, "recenter_on_power_on", True),
            double_click_s=_num(d, "double_click_s", 0.5, 0.1, 3.0),
            scroll_gain=_num(d, "scroll_gain", 0.0, 0.0, 50.0),
            scroll_natural=_bool(d, "scroll_natural", False),
            scroll_deadzone=_num(d, "scroll_deadzone", 0.035, 0.0, 0.49),
            scroll_min_px_per_s=_num(d, "scroll_min_px_per_s", 90.0, 0.0, 5000.0),
            scroll_rate_px_per_s=_num(d, "scroll_rate_px_per_s", 2400.0, 0.0, 20000.0),
            scroll_rate_expo=_num(d, "scroll_rate_expo", 1.7, 0.2, 6.0),
            auto_activate=_bool(d, "auto_activate", False),
            wake_on_any_button=_bool(d, "wake_on_any_button", True),
            auto_deactivate=_bool(d, "auto_deactivate", True),
            pickup_ms=_int(d, "pickup_ms", 300, 0, 5000),
            rest_seconds=_num(d, "rest_seconds", 2.5, 0.1, 60.0),
            rest_tilt_deg=_num(d, "rest_tilt_deg", 15.0, 1.0, 80.0),
            rest_rate_dps=_num(d, "rest_rate_dps", 8.0, 0.0, 500.0),
            idle_hz_when_auto_activate=_int(d, "idle_hz_when_auto_activate", 10, 1, 60),
            timeout_ms=_int(d, "timeout_ms", 500, 100, 10000),
            cert_mode=cert_mode,
            tailscale_host=ts_host,
            transport=transport,
            signaling_url=signaling_url,
            ice_servers=tuple(ice),
            ui=UIConfig(haptics=_bool(ui, "haptics", True), keep_awake=keep_awake,
                        appearance=appearance, layout=layout_name),
        )


def load_pointer_config(path: Path) -> PointerConfig:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise ConfigError(f"cannot read {path.name}: {e}") from e
    return PointerConfig.from_dict(data)


# --- layout -----------------------------------------------------------------

@dataclass(frozen=True)
class LayoutButton:
    id: str
    role: str
    x: float
    y: float
    w: float
    h: float
    label: str = ""
    icon: str | None = None
    css_class: str = ""

    def to_dict(self) -> dict:
        d = {"id": self.id, "role": self.role, "x": self.x, "y": self.y, "w": self.w, "h": self.h,
             "label": self.label}
        if self.icon:
            d["icon"] = self.icon
        if self.css_class:
            d["class"] = self.css_class
        return d


@dataclass(frozen=True)
class Layout:
    version: int
    buttons: tuple[LayoutButton, ...]

    def roles(self) -> dict[str, str]:
        """Map of button id -> role, consumed by the engine."""
        return {b.id: b.role for b in self.buttons}

    def to_dict(self) -> dict:
        return {"version": self.version, "buttons": [b.to_dict() for b in self.buttons]}


def parse_layout(d: Any) -> Layout:
    if not isinstance(d, dict):
        raise ConfigError("layout.json must contain an object")
    version = _int(d, "version", 1, 1, 1)
    raw = d.get("buttons")
    if not isinstance(raw, list) or not raw or len(raw) > 16:
        raise ConfigError("buttons: expected a list of 1..16 buttons")
    buttons: list[LayoutButton] = []
    seen_ids: set[str] = set()
    role_count: dict[str, int] = {}
    for i, b in enumerate(raw):
        if not isinstance(b, dict):
            raise ConfigError(f"buttons[{i}]: expected an object")
        bid = b.get("id")
        if not isinstance(bid, str) or not BUTTON_ID_RE.match(bid):
            raise ConfigError(f"buttons[{i}].id: must match [a-z0-9_-]{{1,32}}")
        if bid in seen_ids:
            raise ConfigError(f"buttons[{i}].id: duplicate '{bid}'")
        seen_ids.add(bid)
        role = b.get("role")
        if role not in ROLES:
            raise ConfigError(f"buttons[{i}].role: must be one of {sorted(ROLES)}")
        role_count[role] = role_count.get(role, 0) + 1
        x, y = _num(b, "x", 0, 0, 100), _num(b, "y", 0, 0, 100)
        w, h = _num(b, "w", 10, 0.5, 100), _num(b, "h", 10, 0.5, 100)
        if x + w > 100.0001 or y + h > 100.0001:
            raise ConfigError(f"buttons[{i}]: x+w and y+h must be <= 100")
        label = b.get("label", "")
        if not isinstance(label, str) or len(label) > 32:
            raise ConfigError(f"buttons[{i}].label: expected string <= 32 chars")
        icon = b.get("icon")
        if icon is not None and (not isinstance(icon, str)
                                 or not re.fullmatch(r"[A-Za-z0-9_./-]+", icon)
                                 or ".." in icon):
            raise ConfigError(f"buttons[{i}].icon: expected a relative path under assets/")
        css_class = b.get("class", "")
        if not isinstance(css_class, str) or not re.fullmatch(r"[A-Za-z0-9_ -]*", css_class):
            raise ConfigError(f"buttons[{i}].class: expected CSS class names")
        buttons.append(LayoutButton(bid, role, x, y, w, h, label, icon, css_class))
    # A power button is optional: with wake_on_any_button the first press on any
    # button arms the pointer. More than one would still be ambiguous.
    if role_count.get("power", 0) > 1:
        raise ConfigError("at most one button may have role 'power'")
    for r in SINGLETON_ROLES:
        if role_count.get(r, 0) > 1:
            raise ConfigError(f"at most one button may have role '{r}'")
    return Layout(version=version, buttons=tuple(buttons))


def load_layout(path: Path) -> Layout:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise ConfigError(f"cannot read {path.name}: {e}") from e
    return parse_layout(data)


# --- watcher ----------------------------------------------------------------

class FileWatcher:
    """Polls file mtimes; `changed()` returns the paths modified since the previous call."""

    def __init__(self, paths: list[Path]):
        self._paths = list(paths)
        self._mtimes = {p: self._mtime(p) for p in self._paths}

    @staticmethod
    def _mtime(p: Path) -> float | None:
        try:
            return os.stat(p).st_mtime_ns
        except OSError:
            return None

    def changed(self) -> list[Path]:
        out = []
        for p in self._paths:
            m = self._mtime(p)
            if m != self._mtimes[p]:
                self._mtimes[p] = m
                out.append(p)
        return out
