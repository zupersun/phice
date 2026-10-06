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
    {"recenter_hold_ms": 10},
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
    assert len(backups) == 6  # layout, theme, panel, howto, calibrate, assets/
    assert paths.theme_css.read_text() == (DEFAULTS_DIR / "theme.css").read_text()


def test_ensure_creates_menubar_icons(tmp_path):
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    for name in ("warn", "disconnected", "off", "on"):
        p = paths.assets / "menubar" / f"{name}.png"
        assert p.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
    assert (paths.assets / "logo.svg").read_text().startswith("<svg")
    # The Home Screen icon existed for the page the Mac used to serve itself.
    assert not (paths.assets / "apple-touch-icon.png").exists()


def test_ensure_never_overwrites_user_assets(tmp_path):
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    (paths.assets / "logo.svg").write_text("<svg>mine</svg>")
    (paths.assets / "menubar" / "on.png").write_bytes(b"mine")
    paths.ensure()
    assert (paths.assets / "logo.svg").read_text() == "<svg>mine</svg>"
    assert (paths.assets / "menubar" / "on.png").read_bytes() == b"mine"


def test_settings_from_the_tls_era_are_ignored_not_rejected():
    """Installs that predate the hosted page still carry cert_mode, transport and
    tailscale_host in pointer.json. Rejecting them would kill the pointer on
    the first launch after an upgrade, so they are simply not read."""
    cfg = PointerConfig.from_dict({"cert_mode": "tailscale", "transport": "tls",
                                   "tailscale_host": "mac.tail1234.ts.net"})
    assert cfg == PointerConfig()
    for gone in ("cert_mode", "transport", "tailscale_host"):
        assert not hasattr(cfg, gone)


def test_layout_no_longer_requires_a_power_button():
    """The pointer wakes on any button, so a power button is optional."""
    layout = parse_layout(_layout([_btn(id="left", role="left"),
                                   _btn(id="right", role="right", x=50)]))
    assert "power" not in layout.roles().values()


def test_layout_still_rejects_two_power_buttons():
    with pytest.raises(ConfigError):
        parse_layout(_layout([_btn(), _btn(id="p2", role="power", x=50)]))


def test_signaling_url_setting():
    assert PointerConfig.from_dict({}).signaling_url == "https://phice.vercel.app"
    cfg = PointerConfig.from_dict({"signaling_url": "https://example.test"})
    assert cfg.signaling_url == "https://example.test"


@pytest.mark.parametrize("bad", [
    {"signaling_url": "ftp://example.test"},
    {"signaling_url": "http://example.test"},   # signaling must be HTTPS
    {"signaling_url": 42},
])
def test_rejects_bad_signaling_urls(bad):
    with pytest.raises(ConfigError):
        PointerConfig.from_dict(bad)


PRESETS = {"standard", "thumb-left", "thumb-centre", "thumb-right"}


def _preset(name):
    from phice.config import load_layout
    from phice.paths import DEFAULTS_DIR
    return {b.id: b for b in load_layout(DEFAULTS_DIR / "layouts" / f"{name}.json").buttons}


def test_every_shipped_layout_is_valid(tmp_path):
    """A layout that fails to load leaves the phone with no buttons at all, which
    is indistinguishable from a broken app."""
    from phice.config import load_layout
    from phice.paths import DEFAULTS_DIR

    presets = sorted((DEFAULTS_DIR / "layouts").glob("*.json"))
    assert {p.stem for p in presets} == PRESETS
    for preset in presets:
        layout = load_layout(preset)
        assert set(layout.roles().values()) == {"left", "right", "scroll", "power"}


def test_the_mouse_sits_at_the_top_with_power_right_beneath():
    """Power is also the recentre control and gets used, so it is a pill you can
    hit directly under the pads, not tucked away at the bottom."""
    std = _preset("standard")
    pads = [std[n] for n in ("left", "right", "scroll")]
    assert all(b.y <= 2 for b in pads), "the pads start at the top"
    bottom = max(b.y + b.h for b in pads)
    assert bottom <= std["power"].y <= bottom + 8, "power right beneath, in reach"
    assert std["power"].w >= 16, "a pill, not a dot"
    assert all(not b.css_class for b in std.values()), "the plain layout: nothing moves it"


def test_ui_layout_rejects_a_path_instead_of_a_name(tmp_path):
    """It names a file in layouts/; anything with a separator is not a name."""
    import json

    import pytest

    from phice.config import ConfigError, load_pointer_config
    p = tmp_path / "pointer.json"
    p.write_text(json.dumps({"ui": {"layout": "../../etc/passwd"}}))
    with pytest.raises(ConfigError):
        load_pointer_config(p)


def test_the_shipped_layout_is_the_mouse_and_a_choice_is_remembered(tmp_path):
    """Ships as the mouse for anyone new, and whatever is chosen after that
    persists, because it is written into pointer.json rather than held in
    memory."""
    import json

    from phice.config import PointerConfig, load_pointer_config

    assert PointerConfig().ui.layout == "standard"

    p = tmp_path / "pointer.json"
    p.write_text(json.dumps({}))
    assert load_pointer_config(p).ui.layout == "standard", "absent means the mouse"

    p.write_text(json.dumps({"ui": {"layout": "thumb-right"}}))
    assert load_pointer_config(p).ui.layout == "thumb-right", "a choice is honoured"

    # Empty still means layout.json, for installs that predate presets.
    p.write_text(json.dumps({"ui": {"layout": ""}}))
    assert load_pointer_config(p).ui.layout == ""


def test_the_thumb_layouts_stack_at_the_edge_under_the_thumb():
    """One block for the hand holding the phone: left click above right click
    against the edge, the wheel beside them on the centre side, power one
    short reach further in. The layout puts the block at the top; the theme
    slides it by --block-y, so it has to leave room to travel."""
    r, lh = _preset("thumb-right"), _preset("thumb-left")
    for hand, b in (("right", r), ("left", lh)):
        assert b["left"].y + b["left"].h <= b["right"].y, f"{hand}: left click above right"
        assert (b["left"].x, b["left"].w) == (b["right"].x, b["right"].w), f"{hand}: one stack"
        assert b["left"].label == "L" and b["right"].label == "R", f"{hand}: says which is which"
        assert all(("thumb" in btn.css_class) for btn in b.values()), f"{hand}: the theme moves it"
        assert min(btn.y for btn in b.values()) <= 2, f"{hand}: starts at the top"
        assert max(btn.y + btn.h for btn in b.values()) <= 45, f"{hand}: room to slide down"
    # Right hand: the stack hugs the right edge, the wheel is to its left, power further left.
    assert r["left"].x + r["left"].w >= 95
    assert r["scroll"].x + r["scroll"].w <= r["left"].x
    assert r["power"].x + r["power"].w <= r["scroll"].x
    # Left hand is the mirror image.
    for name in ("left", "right", "scroll", "power"):
        assert lh[name].x == 100 - (r[name].x + r[name].w), f"{name} mirrors"
        assert (lh[name].y, lh[name].w, lh[name].h) == (r[name].y, r[name].w, r[name].h)


def test_the_centred_layout_is_the_mouse_made_movable():
    std, c = _preset("standard"), _preset("thumb-centre")
    for name in ("left", "right", "scroll", "power"):
        assert (c[name].x, c[name].y, c[name].w, c[name].h) == \
            (std[name].x, std[name].y, std[name].w, std[name].h), name
        assert "ergo-c" in c[name].css_class, "the theme slides this one"
    assert max(b.y + b.h for b in c.values()) <= 56, "room to slide down"


def test_ui_block_y_is_a_share_of_the_pad(tmp_path):
    """Where the block sits, 0 at the top and 1 at the bottom. A number the
    theme interprets, so anything outside that range is a config error."""
    import json

    import pytest

    from phice.config import ConfigError, PointerConfig, load_pointer_config

    assert PointerConfig().ui.block_y == 0.65
    p = tmp_path / "pointer.json"
    p.write_text(json.dumps({"ui": {"block_y": 0.2}}))
    assert load_pointer_config(p).ui.block_y == 0.2
    for bad in (1.5, -0.1, "low", True):
        p.write_text(json.dumps({"ui": {"block_y": bad}}))
        with pytest.raises(ConfigError):
            load_pointer_config(p)


def _alpha_grid(png: bytes) -> list[list[int]]:
    """Decode one of our own grayscale+alpha PNGs back to its alpha values."""
    import zlib
    w = int.from_bytes(png[16:20], "big")
    i = png.index(b"IDAT")
    n = int.from_bytes(png[i - 4:i], "big")
    raw = zlib.decompress(png[i + 4:i + 4 + n])
    stride = w * 2 + 1
    return [[raw[r * stride + 1 + c * 2 + 1] for c in range(w)]
            for r in range(len(raw) // stride)]


def test_the_menu_bar_wears_the_logo_in_four_weights():
    """One mark in the menu bar rather than four drawings of a mouse: filled while
    a phone is connected, outlined when none is, and the weight saying how live the
    pointer is. The parting is cut out of all four -- it is what makes the mark a
    mouse rather than a pill, and it must survive being rasterised this small."""
    from phice.icons import SIZE, icon_disconnected, icon_off, icon_on, icon_warn
    g = {n: _alpha_grid(f()) for n, f in (("on", icon_on), ("off", icon_off),
                                         ("disconnected", icon_disconnected),
                                         ("warn", icon_warn))}
    ink = {n: sum(sum(row) for row in grid) for n, grid in g.items()}
    assert ink["on"] > ink["off"], "an armed pointer is the heaviest"
    assert ink["off"] > ink["disconnected"] and ink["off"] > ink["warn"], \
        "a connected phone is filled; the hollow ones carry less ink"
    assert ink["warn"] > ink["disconnected"], "the one that needs you is the brighter outline"
    mid = SIZE // 2
    for n in ("on", "off"):
        assert g[n][26][mid] > 150, f"{n} is filled"
    for n in ("disconnected", "warn"):
        assert g[n][26][mid] == 0, f"{n} is hollow"
    for n in ("on", "off"):
        assert g[n][10][mid] == 0, f"{n} has the parting cut out of it"
    for n in ("disconnected", "warn"):
        assert g[n][10][mid] > 0, f"{n} draws the parting instead, or it reads as a pill"
    for n, grid in g.items():
        assert grid[10][mid - 9] > 0, f"{n} has a body either side of it"


def test_the_logo_is_the_mark_alone_and_the_name_is_never_shouted():
    """The shipped logo is the mouse and nothing else: no lettering baked in, so the
    panel can set Phice beside it in the window's own type and anyone can use the
    mark on its own. The name is a word, not an acronym -- never in capitals."""
    from phice.icons import LOGO_PATH, LOGO_SVG
    from phice.templates import PANEL_HTML
    assert LOGO_PATH.count("M ") == 2, "the body, and the parting cut out of it"
    assert 'fill-rule="evenodd"' in LOGO_SVG and "currentColor" in LOGO_SVG
    assert "<text" not in LOGO_SVG, "no lettering in the mark"
    for where in (LOGO_SVG, PANEL_HTML):
        assert "PHICE" not in where
    assert "Phice" in PANEL_HTML
