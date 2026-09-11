"""Command line interface."""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

from .certs import CertPaths, ensure_server_cert, local_hostname, local_ipv4s
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


def cmd_run(args) -> int:
    from .runtime import Runtime, setup_logging
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
    print(f"certificate (on the phone): http://{host}.local:{args.http_port}/ca.crt")
    print(f"phone page:                 https://{host}.local:{args.tls_port}/")
    ips = local_ipv4s()
    if ips:
        print("\nif .local does not resolve on your network, use the IP instead:")
        for ip in ips:
            print(f"certificate (on the phone): http://{ip}:{args.http_port}/ca.crt")
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


def _plist(python: str, config_dir: Path, logs: Path) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{python}</string><string>-m</string><string>phice</string>
    <string>--config-dir</string><string>{config_dir}</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>{logs / 'launchd.out.log'}</string>
  <key>StandardErrorPath</key><string>{logs / 'launchd.err.log'}</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
</dict>
</plist>
"""


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
    ):
        sp = sub.add_parser(name, help=help_text)
        sp.set_defaults(func=fn)

    args = ap.parse_args(argv)
    return args.func(args)
