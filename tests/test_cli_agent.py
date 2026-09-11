import plistlib
import sys

from phice import cli


def test_plist_runs_the_module_when_not_frozen(monkeypatch, tmp_path):
    monkeypatch.setattr(sys, "frozen", False, raising=False)
    d = plistlib.loads(cli._plist("/usr/bin/python3", tmp_path, tmp_path).encode())
    args = d["ProgramArguments"]
    assert args[:3] == ["/usr/bin/python3", "-m", "phice"]
    assert args[-1] == "run"
    assert "--config-dir" in args
    # --config-dir is a top-level argparse option: it must precede the subcommand.
    assert args.index("--config-dir") < args.index("run")


def test_plist_runs_the_bundle_executable_when_frozen(monkeypatch, tmp_path):
    """A frozen bundle is its own interpreter: `-m phice` would be passed to the
    app as an argument, not understood as a module."""
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    exe = "/Applications/Phice.app/Contents/MacOS/Phice"
    d = plistlib.loads(cli._plist(exe, tmp_path, tmp_path).encode())
    args = d["ProgramArguments"]
    assert args[0] == exe
    assert "-m" not in args
    assert args[-1] == "run"
    assert args.index("--config-dir") < args.index("run")


def test_plist_is_valid_and_keeps_its_label(tmp_path):
    d = plistlib.loads(cli._plist("/x", tmp_path, tmp_path).encode())
    assert d["Label"] == cli.LABEL
    assert d["RunAtLoad"] is True and d["KeepAlive"] is False


def test_plist_survives_a_config_dir_containing_spaces(tmp_path):
    """The real config dir is ~/Library/Application Support/Phice."""
    d = plistlib.loads(cli._plist("/x", tmp_path / "Application Support" / "Phice",
                                  tmp_path).encode())
    args = d["ProgramArguments"]
    assert any("Application Support" in a for a in args)
