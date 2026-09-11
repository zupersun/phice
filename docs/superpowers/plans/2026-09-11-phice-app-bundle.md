# Phice.app Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Phice into a double-clickable `Phice.app` that a user drags to Applications, with no terminal, no `uv`, and no `git clone` — and which appears in System Settings as **Phice** rather than `python3.13`.

**Architecture:** PyInstaller freezes the existing Python app into a macOS `.app` bundle marked `LSUIElement` (menu-bar only, no Dock icon). The only code change is how packaged resources are located: `paths.py` currently derives them from `__file__`, which does not exist inside a frozen bundle. The launch agent is repointed at the bundle executable, which also means macOS grants Accessibility to *Phice*, giving it a real name and icon in the permission list.

**Tech Stack:** PyInstaller 6.22, existing Python 3.13 app, `launchctl`.

**Source context:** `CLAUDE.md` in the repo root. This plan changes packaging only — `engine.py`, `protocol.py`, `config.py` and `cursor_backend.py` are not touched.

---

## Pre-flight

### Why this is worth doing

Today a user must install `uv`, clone the repo, run `uv sync`, run `phice install`, run `phice grant`, find a hidden directory in System Settings, and grant Accessibility to something called `python3.13`. After this plan: drag an app to Applications, open it, click Allow.

### Two facts that shape the work

1. **`paths.py` uses `Path(__file__).resolve().parent`.** Inside a PyInstaller bundle there is no `__file__` directory holding `defaults/` and `web/`; data files are unpacked to `sys._MEIPASS`. This is the only code that breaks, and it is three constants in one file.
2. **Accessibility is granted per executable.** Repointing the launch agent at `Phice.app/Contents/MacOS/Phice` means the existing `python3.13` grant no longer applies. That is the point — the user re-grants once, to something legible.

### What is deliberately not in scope

Code signing and notarization. They need the $99/year Apple Developer Program. An unsigned bundle runs fine for the person who built it; anyone else must right-click → Open the first time. Notarizing later changes the build step only, not the architecture.

---

## File structure

```
packaging/
  phice.spec          PyInstaller spec: bundle contents, Info.plist, LSUIElement
  build.sh            one command to produce dist/Phice.app
  entry.py            bundle entry point (runs the menu bar app)
src/phice/
  paths.py            MODIFIED: resource_dir() works frozen and unfrozen
  cli.py              MODIFIED: launch agent points at the bundle when frozen
tests/
  test_paths.py       NEW: resource resolution, frozen and unfrozen
```

---

### Task 1: Make resource lookup work inside a frozen bundle

**Files:**
- Modify: `src/phice/paths.py:11-13`
- Test: `tests/test_paths.py` (create)

`PACKAGE_DIR` is derived from `__file__`. PyInstaller unpacks data files to a temporary directory named by `sys._MEIPASS` instead. One helper covers both cases, and every other module keeps importing `DEFAULTS_DIR` / `WEB_DIR` unchanged.

- [ ] **Step 1: Write the failing test — `tests/test_paths.py`**

```python
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
```

- [ ] **Step 2: Run it and watch it fail**

Run: `uv run pytest tests/test_paths.py -q`
Expected: FAIL, `AttributeError: module 'phice.paths' has no attribute 'resource_dir'`

- [ ] **Step 3: Modify `src/phice/paths.py`**

Replace lines 11-13 (`PACKAGE_DIR` / `DEFAULTS_DIR` / `WEB_DIR`) with:

```python
def resource_dir() -> Path:
    """Directory holding packaged defaults/ and web/.

    PyInstaller unpacks data files to sys._MEIPASS rather than leaving them
    beside __file__, so the frozen bundle must be asked where they went.
    """
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS)  # type: ignore[attr-defined]
    return Path(__file__).resolve().parent


PACKAGE_DIR = resource_dir()
DEFAULTS_DIR = PACKAGE_DIR / "defaults"
WEB_DIR = PACKAGE_DIR / "web"
```

Add `import sys` to the imports at the top of the file.

- [ ] **Step 4: Run it and watch it pass**

Run: `uv run pytest tests/test_paths.py -q`
Expected: `3 passed`

- [ ] **Step 5: Confirm nothing else broke**

Run: `uv run pytest -q && uv run ruff check .`
Expected: `137 passed`, `All checks passed!`

- [ ] **Step 6: Commit**

```bash
git add src/phice/paths.py tests/test_paths.py
git commit -m "feat: locate packaged resources inside a frozen bundle"
```

---

### Task 2: Bundle entry point

**Files:**
- Create: `packaging/entry.py`

The bundle cannot use the `phice` console script: PyInstaller needs a plain module to start from, and the bundle must default to running the menu bar rather than printing argparse help.

- [ ] **Step 1: Create `packaging/entry.py`**

```python
"""Entry point for the frozen Phice.app bundle.

Double-clicking the app must start the menu bar, not print CLI help, so the
default argv is `run`. Arguments still pass through when the executable is
invoked from a terminal or by the launch agent.
"""
import multiprocessing
import sys

from phice.cli import main

if __name__ == "__main__":
    multiprocessing.freeze_support()
    argv = sys.argv[1:] or ["run"]
    sys.exit(main(argv))
```

- [ ] **Step 2: Verify it runs unfrozen**

Run: `uv run python packaging/entry.py paths`
Expected: the config path table, proving argv pass-through works.

- [ ] **Step 3: Commit**

```bash
git add packaging/entry.py
git commit -m "feat: bundle entry point defaulting to the menu bar"
```

---

### Task 3: PyInstaller spec

**Files:**
- Create: `packaging/phice.spec`
- Modify: `pyproject.toml` (add pyinstaller to the dev group)

`LSUIElement` is what makes it a menu-bar app with no Dock icon. `CFBundleIdentifier` must be stable — macOS keys the Accessibility grant to it, so changing it later silently drops the permission.

- [ ] **Step 1: Add PyInstaller to the dev dependencies**

In `pyproject.toml`, change the `[dependency-groups]` dev line to:

```toml
dev = ["pytest>=8", "pytest-asyncio>=0.23", "ruff>=0.6", "pyinstaller>=6.22"]
```

Run: `uv sync`
Expected: `pyinstaller` appears in the installed list.

- [ ] **Step 2: Create `packaging/phice.spec`**

```python
# PyInstaller spec for Phice.app
#   uv run pyinstaller packaging/phice.spec --noconfirm
# Produces dist/Phice.app
from PyInstaller.utils.hooks import collect_submodules

block_cipher = None

# defaults/ and web/ must land at the bundle root, because paths.resource_dir()
# returns sys._MEIPASS and looks for them directly beneath it.
datas = [
    ("../src/phice/defaults", "defaults"),
    ("../src/phice/web", "web"),
]

hiddenimports = collect_submodules("rumps") + [
    "Quartz", "AppKit", "Foundation", "ApplicationServices", "objc",
]

a = Analysis(
    ["entry.py"],
    pathex=["../src"],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    # Trim media machinery pulled in by transitive deps but never used.
    excludes=["tkinter", "matplotlib", "numpy.testing", "pytest"],
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="Phice",
    debug=False,
    strip=False,
    upx=False,
    console=False,          # no terminal window
)
coll = COLLECT(
    exe, a.binaries, a.zipfiles, a.datas,
    strip=False, upx=False, name="Phice",
)
app = BUNDLE(
    coll,
    name="Phice.app",
    icon=None,
    bundle_identifier="com.phice.app",   # stable: the Accessibility grant keys on this
    info_plist={
        "LSUIElement": True,             # menu bar only, no Dock icon
        "CFBundleName": "Phice",
        "CFBundleDisplayName": "Phice",
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "0.2.0",
        "NSHumanReadableCopyright": "",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
    },
)
```

- [ ] **Step 3: Commit**

```bash
git add packaging/phice.spec pyproject.toml uv.lock
git commit -m "feat: PyInstaller spec for a menu-bar-only Phice.app"
```

---

### Task 4: Build script

**Files:**
- Create: `packaging/build.sh`

- [ ] **Step 1: Create `packaging/build.sh`**

```bash
#!/usr/bin/env bash
# Build dist/Phice.app. Run from the repo root: ./packaging/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> tests must pass before shipping a bundle"
uv run pytest -q

echo "==> cleaning previous build"
rm -rf build dist

echo "==> freezing"
uv run pyinstaller packaging/phice.spec --noconfirm --log-level WARN

test -d dist/Phice.app || { echo "build produced no bundle"; exit 1; }

echo "==> verifying packaged resources survived"
R="dist/Phice.app/Contents/Frameworks"
for f in defaults/pointer.json defaults/layout.json defaults/theme.css \
         web/index.html web/app.js; do
  test -f "$R/$f" || { echo "MISSING from bundle: $f"; exit 1; }
done

echo "==> built $(du -sh dist/Phice.app | cut -f1)  dist/Phice.app"
echo "    open it with:  open dist/Phice.app"
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x packaging/build.sh
./packaging/build.sh
```

Expected: tests pass, then `built  <size>  dist/Phice.app`.

If the resource check fails, PyInstaller placed data elsewhere. Find the real location with:
`find dist/Phice.app -name pointer.json` and correct the `R=` path in the script.

- [ ] **Step 3: Confirm the bundle actually runs**

```bash
dist/Phice.app/Contents/MacOS/Phice paths
```
Expected: the config path table, printed from inside the bundle. This proves `resource_dir()` resolved correctly while frozen.

- [ ] **Step 4: Confirm it starts as a menu-bar app**

```bash
open dist/Phice.app
sleep 5
pgrep -fl "Phice.app" | head -2
curl -s http://127.0.0.1:8080/debug/cursor | python3 -m json.tool
```
Expected: a running process, and a status snapshot. No Dock icon appears (that is `LSUIElement`).

Stop it: `pkill -f "Phice.app"`

- [ ] **Step 5: Commit**

```bash
git add packaging/build.sh
git commit -m "feat: one-command build producing dist/Phice.app"
```

---

### Task 5: Point the launch agent at the bundle

**Files:**
- Modify: `src/phice/cli.py` (`_plist`, `cmd_install`)
- Test: `tests/test_cli_agent.py` (create)

When running frozen, `sys.executable` is the bundle executable itself and must be launched with no `-m phice`. Unfrozen, the current behaviour must be preserved so development is unaffected.

- [ ] **Step 1: Write the failing test — `tests/test_cli_agent.py`**

```python
import plistlib
import sys
from pathlib import Path

from phice import cli


def test_plist_runs_the_module_when_not_frozen(monkeypatch, tmp_path):
    monkeypatch.setattr(sys, "frozen", False, raising=False)
    d = plistlib.loads(cli._plist("/usr/bin/python3", tmp_path, tmp_path).encode())
    args = d["ProgramArguments"]
    assert args[:3] == ["/usr/bin/python3", "-m", "phice"]
    assert args[-1] == "run"
    assert "--config-dir" in args


def test_plist_runs_the_bundle_executable_when_frozen(monkeypatch, tmp_path):
    """A frozen bundle is its own interpreter: `-m phice` would be passed to the
    app as an argument, not understood as a module."""
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    exe = "/Applications/Phice.app/Contents/MacOS/Phice"
    d = plistlib.loads(cli._plist(exe, tmp_path, tmp_path).encode())
    args = d["ProgramArguments"]
    assert args[0] == exe
    assert "-m" not in args and "phice" not in args[1:2]
    assert args[-1] == "run"


def test_plist_is_valid_and_keeps_its_label(tmp_path):
    d = plistlib.loads(cli._plist("/x", tmp_path, tmp_path).encode())
    assert d["Label"] == cli.LABEL
    assert d["RunAtLoad"] is True and d["KeepAlive"] is False
```

- [ ] **Step 2: Run it and watch it fail**

Run: `uv run pytest tests/test_cli_agent.py -q`
Expected: FAIL — the frozen case still emits `-m phice`.

- [ ] **Step 3: Modify `_plist` in `src/phice/cli.py`**

Replace the `<array>` block of `ProgramArguments` by building it in Python. Change the signature and body of `_plist` to:

```python
def _program_arguments(python: str, config_dir: Path) -> list[str]:
    """A frozen bundle is its own interpreter and takes no -m."""
    if getattr(sys, "frozen", False):
        head = [python]
    else:
        head = [python, "-m", "phice"]
    return [*head, "--config-dir", str(config_dir), "run"]


def _plist(python: str, config_dir: Path, logs: Path) -> str:
    args = "".join(f"<string>{a}</string>" for a in _program_arguments(python, config_dir))
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>{args}</array>
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
```

- [ ] **Step 4: Run it and watch it pass**

Run: `uv run pytest tests/test_cli_agent.py -q`
Expected: `3 passed`

- [ ] **Step 5: Run the whole suite**

Run: `uv run pytest -q && uv run ruff check .`
Expected: `140 passed`, `All checks passed!`

- [ ] **Step 6: Commit**

```bash
git add src/phice/cli.py tests/test_cli_agent.py
git commit -m "fix: launch agent runs the bundle executable when frozen"
```

---

### Task 6: Install from the bundle and re-grant Accessibility

**Files:** none (verification task)

- [ ] **Step 1: Install the built app**

```bash
./packaging/build.sh
cp -R dist/Phice.app /Applications/
open /Applications/Phice.app
sleep 4
```

- [ ] **Step 2: Register it as the login agent, from the bundle**

```bash
/Applications/Phice.app/Contents/MacOS/Phice install
sleep 4
launchctl list | grep phice
```
Expected: a PID with exit status `0`.

Confirm the plist now points at the bundle:
```bash
grep -A1 ProgramArguments ~/Library/LaunchAgents/com.phice.agent.plist
```
Expected: `/Applications/Phice.app/Contents/MacOS/Phice`, with no `-m`.

- [ ] **Step 3: Grant Accessibility to the app**

```bash
/Applications/Phice.app/Contents/MacOS/Phice grant
```
Expected: macOS shows a permission dialog. In **System Settings › Privacy & Security › Accessibility** the entry now reads **Phice**, not `python3.13`. Switch it on.

Then restart and confirm:
```bash
/Applications/Phice.app/Contents/MacOS/Phice install
sleep 4
curl -s http://127.0.0.1:8080/debug/cursor | python3 -m json.tool
```
Expected: `"accessibility": true`.

- [ ] **Step 4: Remove the old development grant**

The `python3.13` entry in the Accessibility list is now unused. Remove it with the **−** button so the list reflects reality.

- [ ] **Step 5: Confirm the pointer still works end to end**

Connect the phone, tap POWER, and confirm the cursor moves. Then:
```bash
curl -s http://127.0.0.1:8080/debug/cursor | python3 -m json.tool
```
Expected: `"connected": true`, `"phase": "on"`, `"accessibility": true`.

---

### Task 7: Document it and ignore build output

**Files:**
- Modify: `.gitignore`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: Ignore build artefacts**

Append to `.gitignore`:

```
build/
dist/
*.spec.bak
```

- [ ] **Step 2: Replace the README install section**

Replace the body of `## Install on the Mac (once)` with:

```markdown
Download `Phice.app`, drag it to **Applications**, and open it. Because it is not
notarized, the first launch needs **right-click → Open** rather than a double-click.

It lives in the menu bar — there is no Dock icon and no window. On first run it asks
for **Accessibility** permission, which is what lets it move the cursor; approve it in
System Settings and the app picks it up within a few seconds.

To start it at login, choose **Launch at login** from its menu.

Building it yourself:

```bash
git clone https://github.com/zupersun/phice.git
cd phice && uv sync
./packaging/build.sh          # produces dist/Phice.app
```
```

- [ ] **Step 3: Record the bundle facts in `CLAUDE.md`**

Add to the **macOS integration** section:

```markdown
- **The shipped artefact is `dist/Phice.app`**, built by `./packaging/build.sh`. Packaged
  resources are found through `paths.resource_dir()`, which returns `sys._MEIPASS` when
  frozen — `__file__` does not work inside a bundle.
- **`CFBundleIdentifier` is `com.phice.app` and must not change.** macOS keys the
  Accessibility grant to it; changing it silently drops the permission.
- The launch agent runs the bundle executable directly when frozen. `-m phice` would be
  passed to the app as an argument rather than understood as a module.
```

- [ ] **Step 4: Verify and commit**

```bash
uv run pytest -q && uv run ruff check .
git add -A
git commit -m "docs: document the app bundle and ignore build output"
```

---

## Definition of done

1. `./packaging/build.sh` produces `dist/Phice.app` with tests green first.
2. `dist/Phice.app/Contents/MacOS/Phice paths` prints the config table, proving resources resolve while frozen.
3. Opening the app shows a menu bar item and no Dock icon.
4. The Accessibility entry reads **Phice**.
5. `debug/cursor` reports `accessibility: true`, `connected: true`, `phase: on` with a phone attached.
6. `uv run pytest -q` reports 140 passed and `uv run ruff check .` is clean.

## Out of scope

Code signing, notarization, Sparkle auto-update, a custom app icon, and a DMG installer. Each is worth doing once the shape settles; none changes the architecture.
