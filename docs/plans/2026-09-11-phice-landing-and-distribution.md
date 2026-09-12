# Phice Landing Page and Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A stranger lands on a URL, clicks one button, and is driving their cursor from their phone a minute later — without a terminal, without guessing, and without the app ever appearing to do nothing.

**Architecture:** `build.sh` produces a `.dmg` as well as the `.app`, published to GitHub Releases. The Vercel deployment's `/` is a landing page that detects the visitor's platform and links to the current release. The Mac app grows a first-run window, because the single worst moment today is opening a menu-bar-only app and seeing no evidence it started.

**Tech Stack:** `hdiutil` for the disk image, `gh release` for hosting, static HTML on Vercel, `rumps.Window` for first run.

**Depends on:** the WebRTC transport plan, which creates `web/` and the Vercel project. Build that first; this plan fills in `web/index.html`, which that plan deliberately leaves as a stub.

---

## Pre-flight

### The friction, measured honestly

Audited against the current build:

| Step | State today |
|---|---|
| Find a download | No releases exist; the README says `git clone` |
| Get the artefact | A raw 38 MB `.app` directory, not a disk image |
| First launch | Gatekeeper blocks it: signed `Phice Self Signed`, no Team ID |
| After allowing it | **Nothing visible happens.** Menu-bar only, and the icon lands behind the notch on a notched Mac with a full menu bar |
| Grant Accessibility | No prompt, no guidance, no window |
| Pair the phone | The QR lives at a `127.0.0.1` URL nobody is told about |

The Gatekeeper warning cannot be removed without a paid Developer ID. **Everything else can.**

### The one that matters most

A user who allows the app past Gatekeeper and then sees no window, no dock icon and no menu bar item concludes it did not install. That is a silent failure, and this project has a history of them. The first-run window is the highest-value task here — higher than the landing page.

### Not in scope

Notarization, auto-update, Intel or universal builds, Windows or Linux.

---

## File structure

```
packaging/
  build.sh              MODIFIED: also produce dist/Phice-<version>.dmg
  dmg.sh                NEW: build the disk image with an Applications symlink
  release.sh            NEW: publish the dmg to GitHub Releases

src/phice/
  firstrun.py           NEW: the first-run window and its state
  menubar.py            MODIFIED: show it when setup is incomplete
  cli.py                MODIFIED: `phice firstrun` to reopen it

web/
  index.html            NEW: landing page, platform detection, download
  style.css             NEW: its styling

tests/
  test_firstrun.py      NEW: which step is outstanding, and why
```

---

### Task 1: Decide what the first run should say

**Files:**
- Create: `src/phice/firstrun.py`
- Test: `tests/test_firstrun.py`

Pure logic first: given the current state, which step is the user on? No UI yet, so it is testable.

- [ ] **Step 1: Write the failing test — `tests/test_firstrun.py`**

```python
from phice.firstrun import Step, next_step


def test_accessibility_comes_first():
    """Nothing else matters until the app can actually move the cursor."""
    s = next_step(accessibility=False, connected=False, agent_installed=False)
    assert s is Step.ACCESSIBILITY


def test_then_pairing():
    s = next_step(accessibility=True, connected=False, agent_installed=False)
    assert s is Step.PAIR


def test_then_launch_at_login():
    """Only worth asking once it demonstrably works."""
    s = next_step(accessibility=True, connected=True, agent_installed=False)
    assert s is Step.LOGIN


def test_nothing_left_to_do():
    s = next_step(accessibility=True, connected=True, agent_installed=True)
    assert s is Step.DONE


def test_every_step_has_wording_and_an_action():
    """A step the window cannot render is a step that strands the user."""
    for step in Step:
        assert step.title and step.body
        if step is not Step.DONE:
            assert step.action_label
```

- [ ] **Step 2: Run it and watch it fail**

Run: `uv run pytest tests/test_firstrun.py -q`
Expected: FAIL, `ModuleNotFoundError: No module named 'phice.firstrun'`

- [ ] **Step 3: Write `src/phice/firstrun.py`**

```python
"""What the user still has to do, and how to say it.

Kept separate from the window so the ordering is testable. The order is not
arbitrary: Accessibility first because nothing works without it, pairing second
because it is the proof it works, and launch-at-login last because it is only
worth offering once the thing has demonstrably worked once.
"""
from __future__ import annotations

from enum import Enum


class Step(Enum):
    ACCESSIBILITY = (
        "Let Phice move the cursor",
        "macOS needs your permission before any app can control the pointer. "
        "Approve the dialog, then switch Phice on in the list.",
        "Grant permission",
    )
    PAIR = (
        "Connect your phone",
        "Open the page on your iPhone and enter the code shown here. "
        "Nothing is installed on the phone.",
        "Show the code",
    )
    LOGIN = (
        "Start Phice automatically",
        "Phice is working. Start it when you log in so it is always there.",
        "Start at login",
    )
    DONE = (
        "You're set",
        "Point your phone at the cursor and press any button.",
        "",
    )

    def __init__(self, title: str, body: str, action_label: str):
        self.title = title
        self.body = body
        self.action_label = action_label


def next_step(*, accessibility: bool, connected: bool, agent_installed: bool) -> Step:
    if not accessibility:
        return Step.ACCESSIBILITY
    if not connected:
        return Step.PAIR
    if not agent_installed:
        return Step.LOGIN
    return Step.DONE
```

- [ ] **Step 4: Run it and watch it pass**

Run: `uv run pytest tests/test_firstrun.py -q`
Expected: `5 passed`

- [ ] **Step 5: Commit**

```bash
git add src/phice/firstrun.py tests/test_firstrun.py
git commit -m "feat: first-run step sequencing"
```

---

### Task 2: Show a window on first run

**Files:**
- Modify: `src/phice/menubar.py`, `src/phice/cli.py`

The app currently proves it started only by a menu bar icon that can be invisible. A window removes all doubt.

- [ ] **Step 1: Add the window to `src/phice/menubar.py`**

Add near the other imports:

```python
from .firstrun import Step, next_step
```

Add these methods to the app class:

```python
    def show_first_run(self, _=None) -> None:
        """Tell the user what is left to do, and do it for them where possible.

        The menu bar alone is not proof of life: on a notched Mac with a full
        menu bar a new status item is invisible, so a user who has just allowed
        the app past Gatekeeper sees nothing at all.
        """
        s = self.runtime.status.read()
        step = next_step(accessibility=s["accessibility"],
                         connected=s["connected"],
                         agent_installed=agent_plist_path().exists())
        if step is Step.DONE:
            rumps.alert(title=step.title, message=step.body, ok="Close")
            return
        clicked = rumps.alert(title=step.title, message=step.body,
                              ok=step.action_label, cancel="Later")
        if not clicked:
            return
        if step is Step.ACCESSIBILITY:
            accessibility_trusted(prompt=True)
            subprocess.run(["open", ACCESSIBILITY_PANE])
        elif step is Step.PAIR:
            self.show_setup(None)
        elif step is Step.LOGIN:
            self.toggle_login(None)

    def _maybe_first_run(self) -> None:
        """Open the window once per launch while setup is incomplete."""
        if self._first_run_shown:
            return
        s = self.runtime.status.read()
        if next_step(accessibility=s["accessibility"], connected=s["connected"],
                     agent_installed=agent_plist_path().exists()) is Step.DONE:
            return
        self._first_run_shown = True
        self.show_first_run()
```

In `__init__`, add `self._first_run_shown = False` and add a menu entry:

```python
            rumps.MenuItem("Setup…", callback=self.show_first_run),
```

In `refresh`, after the status is read, add:

```python
        if self._ticks == 3:          # a beat after launch, once state is real
            self._maybe_first_run()
```

Ensure `import subprocess` is present.

- [ ] **Step 2: Add a CLI entry point**

In `cli.py`, next to the other subcommands:

```python
def cmd_firstrun(args) -> int:
    """Reopen the setup window of the running app."""
    import urllib.error
    import urllib.request
    try:
        with urllib.request.urlopen(
                f"http://127.0.0.1:{args.http_port}/debug/firstrun", timeout=5) as r:
            r.read()
    except (urllib.error.URLError, OSError):
        print("Phice does not appear to be running.", file=sys.stderr)
        return 1
    return 0
```

Register it with `("firstrun", cmd_firstrun, "reopen the setup window")`.

- [ ] **Step 3: Verify**

```bash
uv run pytest -q && uv run ruff check .
./packaging/build.sh
rm -rf /Applications/Phice.app && cp -R dist/Phice.app /Applications/
open /Applications/Phice.app
```
Expected: a window appears naming the outstanding step. With everything already set up, no window appears.

- [ ] **Step 4: Commit**

```bash
git add src/phice/menubar.py src/phice/cli.py
git commit -m "feat: first-run window so a fresh install is never silent"
```

---

### Task 3: Build a disk image

**Files:**
- Create: `packaging/dmg.sh`
- Modify: `packaging/build.sh`

A `.dmg` with an Applications symlink is the convention every Mac user already knows. Shipping a bare `.app` folder invites people to run it from Downloads, where it behaves oddly and is deleted by storage cleanups.

- [ ] **Step 1: Create `packaging/dmg.sh`**

```bash
#!/usr/bin/env bash
# Build dist/Phice-<version>.dmg from dist/Phice.app
set -euo pipefail
cd "$(dirname "$0")/.."

test -d dist/Phice.app || { echo "build the app first: ./packaging/build.sh"; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw dist/Phice.app/Contents/Info.plist)"
DMG="dist/Phice-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging"
cp -R dist/Phice.app "$STAGE/"
# The symlink is what makes drag-to-install obvious without any instructions.
ln -s /Applications "$STAGE/Applications"

echo "==> creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Phice" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> verifying it mounts and carries a working app"
MNT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -quiet
test -d "$MNT/Phice.app" || { hdiutil detach "$MNT" -quiet; echo "no app in the dmg"; exit 1; }
"$MNT/Phice.app/Contents/MacOS/Phice" --config-dir "$(mktemp -d)" paths >/dev/null \
  || { hdiutil detach "$MNT" -quiet; echo "the app in the dmg does not run"; exit 1; }
hdiutil detach "$MNT" -quiet
rmdir "$MNT" 2>/dev/null || true

echo "==> built $(du -sh "$DMG" | cut -f1)  $DMG"
```

- [ ] **Step 2: Call it from `build.sh`**

Append to `packaging/build.sh`, before the final echo:

```bash
./packaging/dmg.sh
```

- [ ] **Step 3: Verify**

```bash
chmod +x packaging/dmg.sh
./packaging/build.sh
ls -la dist/*.dmg
```
Expected: a `.dmg` around 38 MB, and the verification step reports the app inside it runs.

- [ ] **Step 4: Commit**

```bash
git add packaging/dmg.sh packaging/build.sh
git commit -m "feat: ship a disk image with a drag-to-Applications layout"
```

---

### Task 4: Publish a release

**Files:**
- Create: `packaging/release.sh`

- [ ] **Step 1: Create `packaging/release.sh`**

```bash
#!/usr/bin/env bash
# Publish dist/Phice-<version>.dmg to GitHub Releases.
#   ./packaging/release.sh [--draft]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(plutil -extract CFBundleShortVersionString raw dist/Phice.app/Contents/Info.plist)"
DMG="dist/Phice-${VERSION}.dmg"
test -f "$DMG" || { echo "no $DMG -- run ./packaging/build.sh"; exit 1; }

# The landing page resolves the download through the `latest` endpoint, so the
# asset name must stay stable in shape: Phice-<version>.dmg
gh release create "v${VERSION}" "$DMG" \
  --title "Phice ${VERSION}" \
  --notes "Drag Phice to Applications.

This build is signed but not notarized, so the first launch needs
**System Settings › Privacy & Security › Open Anyway**. Phice then asks for
Accessibility permission, which is what lets it move the cursor." \
  "$@"

echo "published v${VERSION}"
gh release view "v${VERSION}" --json assets --jq '.assets[].url'
```

- [ ] **Step 2: Verify as a draft first**

```bash
chmod +x packaging/release.sh
./packaging/release.sh --draft
gh release list --limit 3
```
Expected: a draft release carrying the dmg. Delete it with `gh release delete vX.Y.Z --yes` after checking.

- [ ] **Step 3: Commit**

```bash
git add packaging/release.sh
git commit -m "feat: publish the disk image to GitHub Releases"
```

---

### Task 5: The landing page

**Files:**
- Create: `web/index.html`, `web/style.css`

Replaces the stub left by the WebRTC plan. Its job is one button and honest instructions — the Gatekeeper step cannot be hidden, so it must be stated plainly rather than discovered.

- [ ] **Step 1: Create `web/style.css`**

```css
:root {
  --bg: #0b0f14;
  --fg: #e8eef5;
  --dim: #6b7a8c;
  --accent: #3ea6ff;
  --card: #121820;
  --line: #1e2731;
  color-scheme: dark;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--fg);
  font: 17px/1.6 -apple-system, system-ui, "Segoe UI", sans-serif;
  display: flex;
  justify-content: center;
  padding: 8vh 20px 12vh;
}
main { max-width: 640px; width: 100%; }
h1 { font-size: 44px; line-height: 1.1; margin: 0 0 12px; letter-spacing: -0.02em; }
h2 { font-size: 20px; margin: 40px 0 10px; }
p { color: var(--dim); margin: 0 0 16px; }
.lede { font-size: 20px; color: var(--fg); }
.cta {
  display: inline-block;
  background: var(--accent);
  color: #04121f;
  font-weight: 700;
  font-size: 17px;
  padding: 15px 30px;
  border-radius: 13px;
  text-decoration: none;
  margin: 12px 0 6px;
}
.cta[aria-disabled="true"] { background: var(--line); color: var(--dim); }
.meta { font-size: 14px; color: var(--dim); }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px 20px; }
ol { padding-left: 20px; color: var(--dim); }
li { margin: 8px 0; }
b { color: var(--fg); }
code { background: #1a2230; padding: 2px 6px; border-radius: 5px; font-size: 14px; }
a { color: var(--accent); }
.rule { height: 1px; background: var(--line); margin: 44px 0; border: 0; }
```

- [ ] **Step 2: Create `web/index.html`**

```html
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Phice — your iPhone as an air mouse</title>
<meta name="description" content="Point your iPhone at your Mac and the cursor follows. No App Store, no account.">
<link rel="stylesheet" href="/style.css">
<main>
  <h1>Point your phone.<br>Move your cursor.</h1>
  <p class="lede">Phice turns an iPhone into a Wii-remote-style air mouse for macOS.
     There is no iOS app — your phone just opens a web page.</p>

  <p id="download-slot">
    <a class="cta" id="dl" href="https://github.com/zupersun/phice/releases/latest">
      Download for Mac</a><br>
    <span class="meta" id="dl-meta">Apple Silicon · macOS 13 or later</span>
  </p>

  <p class="meta" id="not-mac" hidden>
    Phice runs on a Mac. Open this page on your Mac to download it —
    then use your phone to point.
  </p>

  <h2>First launch</h2>
  <div class="card">
    <ol>
      <li>Open the disk image and drag <b>Phice</b> to <b>Applications</b>.</li>
      <li>Open it. macOS will say it cannot verify the developer — that is expected,
          because Phice is not notarized. Go to
          <b>System Settings › Privacy &amp; Security</b>, scroll down, and click
          <b>Open Anyway</b>.</li>
      <li>Phice asks for <b>Accessibility</b> permission. That is what lets it move
          the cursor; it cannot work without it.</li>
      <li>A window shows a pairing code. Open <a href="/app">this page on your iPhone</a>
          and type it in.</li>
    </ol>
    <p class="meta">Step 2 is the price of not paying Apple $99 a year. Everything
       Phice does runs on your own machine.</p>
  </div>

  <h2>How it works</h2>
  <p>Your phone streams its orientation over an encrypted peer-to-peer connection
     straight to your Mac. Nothing about how you move is stored, and the motion never
     passes through this website — it only introduces the two devices.</p>

  <hr class="rule">
  <p class="meta">
    <a href="https://github.com/zupersun/phice">Source on GitHub</a> · MIT licensed
  </p>
</main>
<script>
  // Platform detection is a courtesy, never a gate: the download link works
  // regardless, because sniffing is wrong often enough to matter.
  const isMac = /Mac/i.test(navigator.platform || "") ||
                /Mac OS X/i.test(navigator.userAgent || "");
  const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent || "") ||
                (/Mac/i.test(navigator.platform || "") && navigator.maxTouchPoints > 1);
  if (isIOS) {
    document.getElementById("download-slot").innerHTML =
      '<a class="cta" href="/app">Open Phice on this phone</a><br>' +
      '<span class="meta">Install the Mac app first, then come back here.</span>';
  } else if (!isMac) {
    document.getElementById("not-mac").hidden = false;
  }
</script>
```

- [ ] **Step 3: Verify locally, then deploy**

```bash
python3 -m http.server 8099 --directory web &
open http://127.0.0.1:8099/
```
Check: the heading renders, the download button points at the releases page, and
the layout holds at 375px wide. Then `kill %1`.

```bash
git add web/index.html web/style.css
git commit -m "feat: landing page with a single download and honest first-launch steps"
git push
```

Vercel deploys on push. Open the deployment URL and confirm `/` is the landing
page and `/app` is still the phone client.

- [ ] **Step 4: Check it on the phone**

Open the deployment root on the iPhone. Expected: the download button is replaced
by **Open Phice on this phone**, since downloading a Mac app there is useless.

---

### Task 6: Point the README at the release

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the install section's first line**

```markdown
**[Download Phice for Mac](https://github.com/zupersun/phice/releases/latest)** —
or read the first-launch steps at [phice.vercel.app](https://phice.vercel.app).
```

Keep the build-it-yourself instructions below it.

- [ ] **Step 2: Verify and commit**

```bash
uv run pytest -q && uv run ruff check .
git add README.md && git commit -m "docs: link the release from the README"
```

---

## Definition of done

1. `./packaging/build.sh` produces both `dist/Phice.app` and `dist/Phice-<version>.dmg`, and the dmg verification confirms the app inside it runs.
2. `./packaging/release.sh --draft` publishes a draft carrying the dmg.
3. Opening a freshly installed app with nothing configured shows a window naming the outstanding step, rather than appearing to do nothing.
4. That window disappears once Accessibility is granted, a phone is paired and the login agent is installed.
5. The landing page loads on a Mac showing a download button, and on an iPhone showing a link to `/app`.
6. `uv run pytest -q` and `uv run ruff check .` stay green.

## Out of scope

Notarization, auto-update, Intel or universal builds, analytics, and anything that requires an Apple Developer account.
