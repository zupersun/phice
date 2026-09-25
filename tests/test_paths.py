import sys

from phice import paths


def test_resource_dir_uses_the_package_when_not_frozen(monkeypatch):
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)
    monkeypatch.setattr(sys, "frozen", False, raising=False)
    d = paths.resource_dir()
    assert (d / "defaults" / "pointer.json").exists()
    assert (d / "web" / "index.html").exists()


def test_resource_dir_uses_meipass_when_frozen(monkeypatch, tmp_path):
    """PyInstaller unpacks data files to sys._MEIPASS; __file__ points into a
    zip that has no defaults/ or web/ beside it."""
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    assert paths.resource_dir() == tmp_path


def test_packaged_resources_all_exist():
    """Checks the packaged resources exist in the source tree. This runs unfrozen
    and never sees a real bundle; the bundle equivalent is enforced by
    `packaging/build.sh`, which runs the built binary and checks its output."""
    d = paths.resource_dir()
    for rel in ("defaults/pointer.json", "defaults/layout.json", "defaults/theme.css",
                "web/index.html", "web/app.js"):
        assert (d / rel).is_file(), rel


def test_resource_dir_falls_back_when_frozen_without_meipass(monkeypatch):
    """Defensive: `frozen` without `_MEIPASS` should not crash."""
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.delattr(sys, "_MEIPASS", raising=False)
    assert (paths.resource_dir() / "defaults" / "pointer.json").exists()


def test_every_module_but_the_engine_stays_under_the_limit():
    """CLAUDE.md: files under 500 lines, engine.py the one deliberate exception."""
    modules = sorted(paths.PACKAGE_DIR.glob("*.py"))
    assert modules
    for module in modules:
        if module.name == "engine.py":
            continue
        assert module.read_text().count("\n") <= 500, module.name
