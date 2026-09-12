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


def test_plist_handles_paths_that_are_not_xml_safe(tmp_path):
    d = tmp_path / "Rock & Roll"
    parsed = plistlib.loads(cli._plist("/x", d, d).encode())
    assert any("Rock & Roll" in a for a in parsed["ProgramArguments"])


def test_the_generated_arguments_are_accepted_by_the_parser(monkeypatch, tmp_path):
    """The ordering assertions above only check shape. This feeds the generated
    argv to the real parser, which is what launchd effectively does."""
    seen = {}
    monkeypatch.setattr(cli, "cmd_run", lambda a: seen.update(vars(a)) or 0)
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    args = plistlib.loads(cli._plist("/x", tmp_path, tmp_path).encode())["ProgramArguments"]
    assert cli.main(args[1:]) == 0          # drop the interpreter
    assert seen["cmd"] == "run" and seen["config_dir"] == str(tmp_path)


def test_the_unfrozen_arguments_are_also_accepted_by_the_parser(monkeypatch, tmp_path):
    seen = {}
    monkeypatch.setattr(cli, "cmd_run", lambda a: seen.update(vars(a)) or 0)
    monkeypatch.setattr(sys, "frozen", False, raising=False)
    args = plistlib.loads(cli._plist("/x", tmp_path, tmp_path).encode())["ProgramArguments"]
    assert cli.main(args[3:]) == 0          # drop interpreter, -m, phice
    assert seen["cmd"] == "run" and seen["config_dir"] == str(tmp_path)


def test_a_second_launch_reopens_the_window_instead_of_starting_a_rival(monkeypatch):
    """Closing the window used to strand the app: the menu bar item can be
    genuinely unreachable behind the notch. Opening Phice again is the escape
    hatch, so a second launch must talk to the first, not fight it."""
    from phice import cli

    asked: list[int] = []

    def fake_ask(port: int) -> bool:
        asked.append(port)
        return True

    monkeypatch.setattr(cli, "_ask_running_instance_to_show_itself", fake_ask)
    args = type("A", (), {"headless": False, "http_port": 8080, "config_dir": None,
                          "tls_port": 8443, "backend": "fake"})
    assert cli.cmd_run(args) == 0
    assert asked == [8080], "it must ask the running instance, not start a second one"
