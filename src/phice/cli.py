"""Command line interface."""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from .cursor_backend import FakeCursor
from .paths import Paths, default_config_dir

LABEL = "com.phice.agent"


def _paths(args) -> Paths:
    p = Paths(Path(args.config_dir).expanduser() if args.config_dir else default_config_dir())
    p.ensure()
    return p


def _backend(name: str):
    if name == "fake":
        return FakeCursor()
    from .cursor_backend import QuartzCursor
    return QuartzCursor()


def _ask_running_instance_to_show_itself(http_port: int) -> bool:
    """If Phice is already running, bring its window up and let this copy exit.

    Opening the app again is the one escape hatch a user is certain to find: the
    menu bar item can be genuinely unreachable, because macOS puts new status
    items to the left of existing ones and a full menu bar pushes them behind
    the notch. Without this, closing the window left the app with no way back.
    """
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{http_port}/debug/panel", timeout=2) as r:
            return r.status == 200
    except (urllib.error.URLError, OSError, ValueError):
        return False   # nothing there, or something else on the port: start normally


def _ask(http_port: int, path: str, timeout: float = 10) -> dict | None:
    """Call a loopback route on the running app, or None if it is not running."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{http_port}{path}", timeout=timeout) as r:
            return json.load(r)
    except (urllib.error.URLError, OSError, ValueError):
        return None


NOT_RUNNING = "Could not reach the running app. Is it started? Try: phice install"


def cmd_run(args) -> int:
    from .runtime import Runtime, setup_logging
    if not args.headless and _ask_running_instance_to_show_itself(args.http_port):
        print("Phice is already running; opened its window.")
        return 0
    paths = _paths(args)
    setup_logging(paths, debug=bool(os.environ.get("PHICE_DEBUG")))
    runtime = Runtime(paths, _backend(args.backend), args.http_port)
    if args.headless:
        try:
            runtime.run_forever()
        except KeyboardInterrupt:
            pass
        return 0
    from .menubar import run_menubar
    return run_menubar(runtime)


def cmd_paths(args) -> int:
    p = _paths(args)
    for name in ("root", "pointer_json", "layout_json", "layouts", "theme_css", "assets",
                 "logs", "sessions"):
        print(f"{name:14s} {getattr(p, name)}")
    return 0


def cmd_reset_ui(args) -> int:
    for b in _paths(args).reset_ui():
        print(f"backed up {b}")
    print("restored layout.json, theme.css, panel.css, calibrate.css and assets/ from defaults")
    return 0


def cmd_calibrate(args) -> int:
    """Ask the running app to start a calibration run."""
    info = _ask(args.http_port, "/calibrate/start")
    if info is None:
        print(NOT_RUNNING, file=sys.stderr)
        return 1
    print(f"Calibration started: {info['trials']} trials on a "
          f"{info['width']}x{info['height']} display.\n"
          "Follow each target with the phone. The window shows what to do.")
    return 0


def cmd_uncalibrate(args) -> int:
    """Stop a calibration run from outside the window it is showing."""
    if _ask(args.http_port, "/calibrate/cancel", timeout=5) is None:
        print("Could not reach the running app.", file=sys.stderr)
        return 1
    print("Calibration stopped.")
    return 0


def cmd_grant(args) -> int:
    """Ask macOS for Accessibility from the running agent, so the right binary is listed."""
    info = _ask(args.http_port, "/debug/grant", timeout=15)
    if info is None:
        print(NOT_RUNNING, file=sys.stderr)
        return 1
    if info["accessibility"]:
        print("Accessibility is granted. The pointer can move the cursor.")
        return 0
    print("macOS should now be showing a permission dialog, or has added an entry to\n"
          "System Settings > Privacy & Security > Accessibility.\n"
          "Turn that entry ON, then run this again to confirm.")
    return 1


def _program_arguments(python: str, config_dir: Path) -> list[str]:
    """A frozen bundle is its own interpreter and takes no -m.

    --config-dir is a top-level argparse option, so it must precede `run`.
    """
    head = [python] if getattr(sys, "frozen", False) else [python, "-m", "phice"]
    return [*head, "--config-dir", str(config_dir), "run"]


def _plist(python: str, config_dir: Path, logs: Path) -> str:
    """Built with plistlib rather than string interpolation: paths can contain
    characters that are not XML-safe."""
    plist = {
        "Label": LABEL,
        "ProgramArguments": _program_arguments(python, config_dir),
        "RunAtLoad": True,
        "KeepAlive": False,
        "ProcessType": "Interactive",
        "StandardOutPath": str(logs / "launchd.out.log"),
        "StandardErrorPath": str(logs / "launchd.err.log"),
        "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    }
    return plistlib.dumps(plist).decode()


def agent_plist_path() -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"


def _bootout(uid: int) -> None:
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], capture_output=True)


def cmd_install(args) -> int:
    paths = _paths(args)
    plist = agent_plist_path()
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_text(_plist(sys.executable, paths.root, paths.logs))
    uid = os.getuid()
    _bootout(uid)
    # launchd tears the service down after bootout returns, so bootstrapping
    # immediately races it and fails. Wait for the label to disappear first.
    for _ in range(30):
        if subprocess.run(["launchctl", "print", f"gui/{uid}/{LABEL}"],
                          capture_output=True).returncode != 0:
            break
        time.sleep(0.1)
    r = subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", str(plist)], capture_output=True,
                       text=True)
    if r.returncode != 0:
        print(f"launchctl bootstrap failed: {r.stderr.strip() or r.returncode}", file=sys.stderr)
        return 1
    print(f"installed and started. Menu bar icon should appear now.\nplist: {plist}")
    return 0


def cmd_uninstall(args) -> int:
    uid = os.getuid()
    _bootout(uid)
    agent_plist_path().unlink(missing_ok=True)
    print("stopped and removed the launch agent")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="phice", description="iPhone air mouse for macOS")
    ap.add_argument("--config-dir")
    ap.add_argument("--http-port", type=int, default=8080)
    sub = ap.add_subparsers(dest="cmd", required=True)

    run = sub.add_parser("run", help="run the app")
    run.add_argument("--backend", choices=["quartz", "fake"], default="quartz")
    run.add_argument("--headless", action="store_true", help="no menu bar (for tests)")
    run.set_defaults(func=cmd_run)

    for name, fn, help_text in (
        ("install", cmd_install, "install and start the login agent"),
        ("uninstall", cmd_uninstall, "stop and remove the login agent"),
        ("paths", cmd_paths, "print config paths"),
        ("reset-ui", cmd_reset_ui, "restore default layout, theme and assets"),
        ("grant", cmd_grant, "ask macOS for Accessibility permission"),
        ("calibrate", cmd_calibrate, "fit the pointer to you by measuring"),
        ("stop-calibrate", cmd_uncalibrate, "stop a calibration run"),
    ):
        sp = sub.add_parser(name, help=help_text)
        sp.set_defaults(func=fn)

    args = ap.parse_args(argv)
    return args.func(args)
