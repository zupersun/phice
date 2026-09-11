import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packaging"))

from entry import default_argv  # noqa: E402


def test_double_click_starts_the_menu_bar():
    """Launching by double-click passes only the executable path."""
    assert default_argv(["/Applications/Phice.app/Contents/MacOS/Phice"]) == ["run"]


def test_arguments_pass_through():
    assert default_argv(["/x", "--config-dir", "/tmp/c", "run"]) == ["--config-dir", "/tmp/c", "run"]
