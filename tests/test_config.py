import json
import os
import time

import pytest

from phice.config import (
    ConfigError,
    FileWatcher,
    PointerConfig,
    load_layout,
    load_pointer_config,
    parse_layout,
)
from phice.paths import DEFAULTS_DIR, Paths


def test_defaults_file_matches_dataclass_defaults():
    cfg = load_pointer_config(DEFAULTS_DIR / "pointer.json")
    assert cfg == PointerConfig()
    assert cfg.idle_hz == 0


def test_partial_config_uses_defaults(tmp_path):
    p = tmp_path / "pointer.json"
    p.write_text(json.dumps({"gain_x_px_per_deg": 40, "auto_activate": True}))
    cfg = load_pointer_config(p)
    assert cfg.gain_x_px_per_deg == 40.0
    assert cfg.gain_y_px_per_deg == 18.0
    assert cfg.idle_hz == 10


@pytest.mark.parametrize("bad", [
    {"gain_x_px_per_deg": 0}, {"gain_x_px_per_deg": "fast"}, {"invert_y": 1},
    {"one_euro": {"min_cutoff": -1}}, {"chord_window_ms": 5000}, {"ui": {"keep_awake": "never"}},
    {"cert_mode": "magic"}, {"recenter_hold_ms": 10},
])
def test_rejects_invalid_values(bad):
    with pytest.raises(ConfigError):
        PointerConfig.from_dict(bad)


def test_unreadable_file_raises(tmp_path):
    p = tmp_path / "pointer.json"
    p.write_text("{oops")
    with pytest.raises(ConfigError):
        load_pointer_config(p)


def test_default_layout_parses():
    """A power button exists to carry the status LED and to shut the pointer
    down, but it is not how you start: any button wakes it."""
    layout = load_layout(DEFAULTS_DIR / "layout.json")
    assert layout.roles() == {"left": "left", "scroll": "scroll", "right": "right",
                              "power": "power"}
    assert all(b["label"] == "" for b in layout.to_dict()["buttons"]), "no text"


def _layout(buttons):
    return {"version": 1, "buttons": buttons}


def _btn(**kw):
    d = {"id": "power", "role": "power", "x": 0, "y": 0, "w": 10, "h": 10}
    d.update(kw)
    return d


@pytest.mark.parametrize("buttons", [
    [],
    [_btn(id="Power")],
    [_btn(role="middle")],
    [_btn(x=95, w=10)],
    [_btn(), _btn(id="p2")],
    [_btn(), _btn(id="a", role="left"), _btn(id="b", role="left")],
    [_btn(icon="../secret.svg")],
])
def test_layout_validation(buttons):
    with pytest.raises(ConfigError):
        parse_layout(_layout(buttons))


def test_layout_allows_optional_roles_and_fields():
    layout = parse_layout(_layout([
        _btn(), _btn(id="c1", role="clutch", x=50), _btn(id="c2", role="clutch", y=50),
        _btn(id="rc", role="recenter", x=50, y=50, icon="icons/target.svg", **{"class": "big"}),
    ]))
    assert layout.roles()["c2"] == "clutch"
    assert layout.to_dict()["buttons"][3]["class"] == "big"


def test_watcher_reports_changes_once(tmp_path):
    p = tmp_path / "a.json"
    p.write_text("1")
    w = FileWatcher([p, tmp_path / "missing"])
    assert w.changed() == []
    time.sleep(0.01)
    p.write_text("2")
    os.utime(p, ns=(time.time_ns(), time.time_ns()))
    assert w.changed() == [p]
    assert w.changed() == []
    (tmp_path / "missing").write_text("x")
    assert w.changed() == [tmp_path / "missing"]


def test_paths_ensure_and_reset(tmp_path):
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    assert paths.pointer_json.exists() and paths.layout_json.exists() and paths.theme_css.exists()
    assert (paths.assets / "logo.svg").exists()
    paths.theme_css.write_text("body{color:red}")
    backups = paths.reset_ui()
    assert len(backups) == 5  # layout, theme, panel, calibrate, assets/
    assert paths.theme_css.read_text() == (DEFAULTS_DIR / "theme.css").read_text()


def test_ensure_creates_menubar_icons_and_touch_icon(tmp_path):
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    for name in ("warn", "disconnected", "off", "on"):
        p = paths.assets / "menubar" / f"{name}.png"
        assert p.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
    assert (paths.assets / "apple-touch-icon.png").read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
    assert (paths.assets / "logo.svg").read_text().startswith("<svg")


def test_ensure_never_overwrites_user_assets(tmp_path):
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    (paths.assets / "logo.svg").write_text("<svg>mine</svg>")
    (paths.assets / "menubar" / "on.png").write_bytes(b"mine")
    paths.ensure()
    assert (paths.assets / "logo.svg").read_text() == "<svg>mine</svg>"
    assert (paths.assets / "menubar" / "on.png").read_bytes() == b"mine"


def test_tailscale_host_is_remembered():
    """The runtime cannot reach the Tailscale GUI's CLI from the launch agent,
    so the name resolved once in a terminal has to survive in config."""
    cfg = PointerConfig.from_dict({"cert_mode": "tailscale",
                                   "tailscale_host": "mac.tail1234.ts.net"})
    assert cfg.cert_mode == "tailscale" and cfg.tailscale_host == "mac.tail1234.ts.net"
    with pytest.raises(ConfigError):
        PointerConfig.from_dict({"tailscale_host": 123})


def test_layout_no_longer_requires_a_power_button():
    """The pointer wakes on any button, so a power button is optional."""
    layout = parse_layout(_layout([_btn(id="left", role="left"),
                                   _btn(id="right", role="right", x=50)]))
    assert "power" not in layout.roles().values()


def test_layout_still_rejects_two_power_buttons():
    with pytest.raises(ConfigError):
        parse_layout(_layout([_btn(), _btn(id="p2", role="power", x=50)]))


def test_transport_settings():
    cfg = PointerConfig.from_dict({})
    assert cfg.transport == "tls"           # unchanged default: nothing breaks yet
    assert cfg.signaling_url == "https://phice.vercel.app"

    cfg = PointerConfig.from_dict({"transport": "webrtc",
                                   "signaling_url": "https://example.test"})
    assert cfg.transport == "webrtc" and cfg.signaling_url == "https://example.test"


@pytest.mark.parametrize("bad", [
    {"transport": "carrier-pigeon"},
    {"signaling_url": "ftp://example.test"},
    {"signaling_url": "http://example.test"},   # signaling must be HTTPS
    {"signaling_url": 42},
])
def test_rejects_bad_transport_settings(bad):
    with pytest.raises(ConfigError):
        PointerConfig.from_dict(bad)


def test_both_shipped_layouts_are_valid(tmp_path):
    """A layout that fails to load leaves the phone with no buttons at all, which
    is indistinguishable from a broken app."""
    from phice.config import load_layout
    from phice.paths import DEFAULTS_DIR

    presets = sorted((DEFAULTS_DIR / "layouts").glob("*.json"))
    assert {p.stem for p in presets} == {"standard", "one-handed"}
    for preset in presets:
        layout = load_layout(preset)
        assert set(layout.roles().values()) == {"left", "right", "scroll", "power"}


def test_the_standard_power_button_sits_lower_than_it_used_to():
    from phice.config import load_layout
    from phice.paths import DEFAULTS_DIR

    buttons = {b.id: b for b in load_layout(DEFAULTS_DIR / "layouts" / "standard.json").buttons}
    assert buttons["power"].y >= 76, "power moved down, away from the pads"


def test_ui_layout_rejects_a_path_instead_of_a_name(tmp_path):
    """It names a file in layouts/; anything with a separator is not a name."""
    import json

    import pytest

    from phice.config import ConfigError, load_pointer_config
    p = tmp_path / "pointer.json"
    p.write_text(json.dumps({"ui": {"layout": "../../etc/passwd"}}))
    with pytest.raises(ConfigError):
        load_pointer_config(p)


def test_the_shipped_layout_is_two_handed_and_a_choice_is_remembered(tmp_path):
    """Ships as two hands for anyone new, and whatever is chosen after that
    persists, because it is written into pointer.json rather than held in
    memory."""
    import json

    from phice.config import PointerConfig, load_pointer_config

    assert PointerConfig().ui.layout == "standard"

    p = tmp_path / "pointer.json"
    p.write_text(json.dumps({}))
    assert load_pointer_config(p).ui.layout == "standard", "absent means two hands"

    p.write_text(json.dumps({"ui": {"layout": "one-handed"}}))
    assert load_pointer_config(p).ui.layout == "one-handed", "a choice is honoured"

    # Empty still means layout.json, for installs that predate presets.
    p.write_text(json.dumps({"ui": {"layout": ""}}))
    assert load_pointer_config(p).ui.layout == ""


def test_one_handed_keeps_power_below_the_pads():
    """The same relationship the two-handed layout has -- power under the pads,
    not over them -- while the pads keep their place in thumb reach."""
    from phice.config import load_layout
    from phice.paths import DEFAULTS_DIR

    one = {b.id: b for b in load_layout(DEFAULTS_DIR / "layouts" / "one-handed.json").buttons}
    std = {b.id: b for b in load_layout(DEFAULTS_DIR / "layouts" / "standard.json").buttons}
    pads = [one[n] for n in ("left", "right", "scroll")]

    assert all(b.y >= 45 for b in pads), "the pads stay in the bottom half"
    assert one["power"].y >= max(b.y + b.h for b in pads), "power sits below the pads"
    assert one["power"].y + one["power"].h <= 100, "and stays on the screen"
    # Both layouts now read the same way: pads, then power underneath.
    assert std["power"].y >= max(std[n].y + std[n].h for n in ("left", "right", "scroll"))
    assert one["left"].x == 100 - (one["right"].x + one["right"].w), "symmetric, either hand"
