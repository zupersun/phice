"""Command line interface."""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path

from .certs import (
    CertError,
    CertPaths,
    ensure_server_cert,
    ensure_tailscale_cert,
    local_hostname,
    local_ipv4s,
    tailscale_bin,
    tailscale_dns_name,
)
from .cursor_backend import FakeCursor
from .pairing import PairingManager
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
    import urllib.error
    import urllib.request
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{http_port}/debug/panel", timeout=2) as r:
            return r.status == 200
    except (urllib.error.URLError, OSError, ValueError):
        return False   # nothing there, or something else on the port: start normally


def cmd_run(args) -> int:
    from .runtime import Runtime, setup_logging
    if not args.headless and _ask_running_instance_to_show_itself(args.http_port):
        print("Phice is already running; opened its window.")
        return 0
    paths = _paths(args)
    setup_logging(paths, debug=bool(os.environ.get("PHICE_DEBUG")))
    runtime = Runtime(paths, _backend(args.backend), args.tls_port, args.http_port)
    if args.headless:
        try:
            runtime.run_forever()
        except KeyboardInterrupt:
            pass
        return 0
    from .menubar import run_menubar
    return run_menubar(runtime)


def cmd_pair_token(args) -> int:
    paths = _paths(args)
    token = PairingManager(paths.devices_json).mint_pairing_token()
    host = local_hostname()
    print(f"https://{host}.local:{args.tls_port}/?pair={token}")
    return 0


def cmd_setup_url(args) -> int:
    host = local_hostname()
    print(f"setup page (on this Mac): http://127.0.0.1:{args.http_port}/setup")
    print(f"certificate (on the phone): http://{host}.local:{args.http_port}/ca.mobileconfig")
    print(f"phone page:                 https://{host}.local:{args.tls_port}/")
    ips = local_ipv4s()
    if ips:
        print("\nif .local does not resolve on your network, use the IP instead:")
        for ip in ips:
            print(f"certificate (on the phone): http://{ip}:{args.http_port}/ca.mobileconfig")
            print(f"phone page:                 https://{ip}:{args.tls_port}/")
    return 0


def cmd_paths(args) -> int:
    p = _paths(args)
    for name in ("root", "pointer_json", "layout_json", "theme_css", "assets", "devices_json",
                 "certs", "logs", "sessions"):
        print(f"{name:14s} {getattr(p, name)}")
    return 0


def cmd_reset_ui(args) -> int:
    for b in _paths(args).reset_ui():
        print(f"backed up {b}")
    print("restored layout.json, theme.css and assets/ from defaults")
    return 0


def cmd_certs(args) -> int:
    paths = _paths(args)
    host = local_hostname()
    issued = ensure_server_cert(CertPaths.under(paths.certs), host)
    print(("issued" if issued else "already current") + f" for {host}.local")
    return 0


def cmd_tailscale(args) -> int:
    """Switch to a publicly trusted tailnet certificate: nothing to install on the phone."""
    paths = _paths(args)
    if not tailscale_bin():
        print("Tailscale is not installed.\n"
              "  brew install --cask tailscale\n"
              "then open Tailscale from Applications and sign in.", file=sys.stderr)
        return 1
    name = tailscale_dns_name()
    if not name:
        print("Tailscale is installed but not logged in. Run: tailscale up", file=sys.stderr)
        return 1
    try:
        ensure_tailscale_cert(CertPaths.under(paths.certs), name)
    except CertError as e:
        print(f"{e}\n\nIf it mentions HTTPS, enable it once for your tailnet:\n"
              "  https://login.tailscale.com/admin/dns -> HTTPS Certificates -> Enable",
              file=sys.stderr)
        return 1
    pointer = paths.pointer_json
    data = json.loads(pointer.read_text())
    data["cert_mode"] = "tailscale"
    data["tailscale_host"] = name
    pointer.write_text(json.dumps(data, indent=2) + "\n")
    print(f"trusted certificate ready for {name}\n"
          f"cert_mode set to 'tailscale' in {pointer}\n"
          f"phone page: https://{name}:{args.tls_port}/\n"
          "Install Tailscale on the iPhone, sign in with the same account, then "
          "scan the QR on the setup page. No profile to install.")
    return 0


def cmd_calibrate(args) -> int:
    """Ask the running app to start a calibration run."""
    import urllib.error
    import urllib.request
    try:
        with urllib.request.urlopen(
                f"http://127.0.0.1:{args.http_port}/calibrate/start", timeout=10) as r:
            info = json.load(r)
    except (urllib.error.URLError, OSError, ValueError):
        print("Could not reach the running app. Is it started? Try: phice install",
              file=sys.stderr)
        return 1
    print(f"Calibration started: {info['trials']} trials on a "
          f"{info['width']}x{info['height']} display.\n"
          "Follow each target with the phone. The window shows what to do.")
    return 0


def cmd_grant(args) -> int:
    """Ask macOS for Accessibility from the running agent, so the right binary is listed."""
    import urllib.error
    import urllib.request
    url = f"http://127.0.0.1:{args.http_port}/debug/grant"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            ok = json.load(r)["accessibility"]
    except (urllib.error.URLError, OSError, ValueError):
        print("Could not reach the running app. Is it started? Try: phice install",
              file=sys.stderr)
        return 1
    if ok:
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


def cmd_webrtc(args) -> int:
    """Switch to the hosted page and the WebRTC transport."""
    paths = _paths(args)
    data = json.loads(paths.pointer_json.read_text())
    data["transport"] = "webrtc"
    if args.signaling_url:
        data["signaling_url"] = args.signaling_url.rstrip("/")
    paths.pointer_json.write_text(json.dumps(data, indent=2) + "\n")
    print(f"transport set to 'webrtc' in {paths.pointer_json}\n"
          f"phone page:   {data['signaling_url']}/app\n"
          f"pairing code: http://127.0.0.1:{args.http_port}/pair\n"
          "Restart for this to take effect: phice install")
    return 0


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
    ap.add_argument("--tls-port", type=int, default=8443)
    ap.add_argument("--http-port", type=int, default=8080)
    sub = ap.add_subparsers(dest="cmd", required=True)

    wrtc = sub.add_parser("webrtc", help="use the hosted page and WebRTC transport")
    wrtc.add_argument("--signaling-url", default=None)
    wrtc.set_defaults(func=cmd_webrtc)

    run = sub.add_parser("run", help="run the app")
    run.add_argument("--backend", choices=["quartz", "fake"], default="quartz")
    run.add_argument("--headless", action="store_true", help="no menu bar (for tests)")
    run.set_defaults(func=cmd_run)

    for name, fn, help_text in (
        ("install", cmd_install, "install and start the login agent"),
        ("uninstall", cmd_uninstall, "stop and remove the login agent"),
        ("pair-token", cmd_pair_token, "mint a pairing URL"),
        ("setup-url", cmd_setup_url, "print setup URLs"),
        ("paths", cmd_paths, "print config paths"),
        ("reset-ui", cmd_reset_ui, "restore default layout, theme and assets"),
        ("certs", cmd_certs, "create or renew the TLS certificate"),
        ("tailscale", cmd_tailscale, "use a trusted tailnet certificate"),
        ("grant", cmd_grant, "ask macOS for Accessibility permission"),
        ("calibrate", cmd_calibrate, "fit the pointer to you by measuring"),
    ):
        sp = sub.add_parser(name, help=help_text)
        sp.set_defaults(func=fn)

    args = ap.parse_args(argv)
    return args.func(args)
