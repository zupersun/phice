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
    """Guards against shipping a bundle whose defaults were never collected."""
    d = paths.resource_dir()
    for rel in ("defaults/pointer.json", "defaults/layout.json", "defaults/theme.css",
                "web/index.html", "web/app.js"):
        assert (d / rel).is_file(), rel
