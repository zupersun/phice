# Phice MVP — Design Spec

Date: 2026-09-11
Status: **historical.** This is the design Phice was built from, kept because it
records why the pointer works the way it does -- the roll-invariant maths, the pure
engine, the data-driven UI, all of which still hold.

What has changed since: the phone page is hosted and pairs by a six-character code
over WebRTC, so no certificate is involved anywhere. Serving the page from the Mac
over TLS, the local CA, the Tailscale certificate and the token-based pairing
described throughout below were removed on 2026-09-22; `tools/fake_phone.py` now
pairs the way the phone does. See the README for how it actually ships.

## 1. Summary

Phice turns an iPhone into a Wii-remote-style air pointer for a Mac.

- **Phone side** is a web page opened in Safari (or added to the Home Screen). It streams orientation
  sensors and touch state to the Mac. No native app, no App Store, no Apple Developer account.
- **Mac side** is a lightweight Python menu-bar app. It serves the page over TLS, receives the stream,
  does all pointer math, and injects cursor events through Quartz.
- **All pointer logic lives on the Mac.** The phone is a dumb sensor plus touch surface.
- **All UI is data-driven** from files the user can edit after build: a layout JSON, a theme CSS, and
  an assets folder for logos and icons. No rebuild is ever needed to change the look.

Phase 2 (camera-based glide mode) is explicitly out of scope.

## 2. Goals and non-goals

### Goals

1. Relative pointing driven by phone orientation; roll around the phone's long axis has no effect.
2. Power toggle on the phone: on takes over the cursor where it currently is; off freezes it.
3. Recenter gesture: hold left + right for one second → cursor snaps to the center of its display.
4. Left click, right click, drag, and a press-and-drag scroll strip.
5. Haptic tick on button press (best effort within Safari's limits).
6. Every visual aspect editable in plain files; hot-reloaded where possible.
7. Lightweight: near-zero idle CPU on the Mac, minimal battery use on the phone.
8. Safe on a shared network: pairing token, TLS, no unauthenticated control.
9. Fully verifiable by an agent without touching a phone: unit tests plus a fake-phone tool.

### Non-goals (MVP)

Native iOS/macOS apps, App Store, camera glide mode, momentum scrolling, keyboard input, gesture
shortcuts beyond those listed, multiple simultaneous phones, WebRTC transport.

## 3. System overview

```
 iPhone (Safari / Home Screen web app)              Mac (menu-bar app, Python)
 ┌──────────────────────────────┐                    ┌───────────────────────────────┐
 │ index.html + app.js          │  wss://mac.local   │ server.py  (TLS :8443)        │
 │  - sensors 60 Hz             │ ───── JSON ──────▶ │   static: /, /app.js,         │
 │  - multitouch buttons        │                    │     /theme.css, /layout.json, │
 │  - renders layout.json       │ ◀──── state ────── │     /assets/*  ;  /ws         │
 │  - styled by theme.css       │                    │ engine.py  (pure pointer math)│
 └──────────────────────────────┘                    │ cursor_backend.py (Quartz)    │
                                                     │ app.py (rumps menu bar)       │
   one-time: http://mac.local:8080/ca.crt            │ http :8080  /ca.crt, /help,   │
   (install + trust the local CA)                    │             /setup (loopback) │
                                                     └───────────────────────────────┘
 Config dir: ~/Library/Application Support/Phice/
   pointer.json  layout.json  theme.css  assets/  devices.json  certs/  logs/  sessions/
```

## 4. Mac app

### 4.1 Runtime and dependencies

- Python 3.12, managed with `uv`. Package name `phice`, source in `src/phice/`.
- Dependencies, kept deliberately small:
  - `websockets` (≥13) — TLS WebSocket server; also serves the static files on the same port via
    `process_request`.
  - `cryptography` — local CA and server certificate generation.
  - `rumps` — menu bar app (pulls `pyobjc-framework-Cocoa`).
  - `pyobjc-framework-Quartz` — cursor events and display enumeration.
  - `pyobjc-framework-ApplicationServices` — Accessibility trust check.
  - `qrcode` — QR codes rendered as inline SVG (no Pillow).
- Dev dependencies: `pytest`, `pytest-asyncio`, `ruff`.
- No numpy, no Pillow, no web framework.

### 4.2 Process model

- `rumps` owns the main thread (AppKit run loop).
- One background thread runs an `asyncio` event loop hosting: the TLS server, the plain HTTP server,
  the config watcher (1 Hz `os.stat` polling), and the engine tick timer (50 Hz, only while a phone
  is connected and the pointer is on; 5 Hz otherwise).
- The engine is called only from the asyncio thread. Quartz event posting from that thread is fine.
- A thread-safe `Status` object is the only shared state. A `rumps.Timer` at 1 Hz copies it into the
  menu (icon, titles). The Accessibility trust check runs in that same timer every third tick.
- Graceful shutdown on Quit / SIGTERM: release held buttons, close connections, stop loop.

### 4.3 Files and paths

| Path | Purpose |
|---|---|
| `~/Library/Application Support/Phice/pointer.json` | Tuning. Hot-reloaded. |
| `.../layout.json` | Button layout for the phone page. Hot-reloaded, pushed to the page. |
| `.../theme.css` | All colors, fonts, radii, spacing for the page. Hot-reloaded. |
| `.../assets/` | `logo.svg`, `icons/*.svg`, `menubar/{warn,disconnected,off,on}.png`. Served as-is. |
| `.../devices.json` | Paired device tokens. |
| `.../certs/` | `ca.key`, `ca.crt`, `server.key`, `server.crt` (mode 0600). |
| `.../logs/phice.log` | Rotating log, 1 MB × 3. |
| `.../sessions/*.jsonl` | Recorded raw packet streams for replay. |
| `~/Library/LaunchAgents/com.phice.agent.plist` | Launch-at-login agent. |

On first run, `pointer.json`, `layout.json`, `theme.css`, and `assets/` are copied from the package's
`defaults/` folder if absent. `phice reset-ui` re-copies the UI files after backing up existing ones
to `*.bak`.

### 4.4 CLI

```
phice run [--backend quartz|fake] [--config-dir PATH] [--tls-port 8443] [--http-port 8080]
phice install          # write LaunchAgent plist and bootstrap it (starts now, no reboot)
phice uninstall        # bootout and remove plist
phice pair-token       # mint and print a fresh pairing token (10 min validity)
phice setup-url        # print the setup page URL and the phone URLs
phice reset-ui         # restore default layout/theme/assets
phice paths            # print config paths
```

`--backend fake` swaps the Quartz cursor for an in-memory cursor and exposes its last commanded
position at `http://127.0.0.1:8080/debug/cursor`. This lets the agent verify end-to-end behavior
without Accessibility permission.

### 4.5 Menu bar

Icon reflects state, using the user-replaceable PNGs in `assets/menubar/` (rendered as template images
at 18×18 pt):

| State | Icon |
|---|---|
| Accessibility not granted | `warn.png` |
| No phone connected | `disconnected.png` |
| Phone connected, pointer off | `off.png` |
| Pointer on | `on.png` |

Menu items:

- Status line (disabled): "Connected: iPhone · Pointer ON" etc.
- Show setup page (opens `http://127.0.0.1:8080/setup` in the default browser)
- Pointer enabled ✓ (global kill switch; unchecked = ignore all motion and clicks)
- Reload config now
- Open config folder
- Record session ✓ (toggle)
- Grant Accessibility… (opens the Privacy & Security → Accessibility pane)
- Launch at login ✓ (toggles presence of the plist file only)
- Revoke all paired devices
- Quit

### 4.6 Servers

**TLS port 8443** (single `websockets` server with `process_request` routing):

| Route | Source | Cache |
|---|---|---|
| `/` | package `web/index.html` | no-store |
| `/app.js` | package `web/app.js` | no-store |
| `/theme.css` | config dir | no-store |
| `/layout.json` | config dir | no-store |
| `/assets/<path>` | config `assets/` (path-traversal safe, allowed extensions: svg png jpg jpeg css json woff2 ico) | max-age=60 |
| `/ws` | WebSocket upgrade | — |
| anything else | 404 | — |

**Plain HTTP port 8080** (stdlib `http.server`, threaded):

| Route | Access | Purpose |
|---|---|---|
| `/ca.crt` | any client | DER-encoded CA certificate, `Content-Type: application/x-x509-ca-cert`. Safari offers to install it as a profile. |
| `/help` | any client | Static instructions for installing and trusting the CA. |
| `/setup` | loopback only | Setup page with two QR codes and text URLs (see §12). Mints a pairing token on each load. |
| `/debug/cursor` | loopback only, fake backend only | JSON `{x, y, buttons, moves, clicks}` |

Both servers bind to all interfaces (except loopback-only routes are enforced by checking the peer
address). Hostname for URLs comes from `scutil --get LocalHostName` + `.local`.

### 4.7 Certificates

- **CA**: ECDSA P-256, CN `Phice Local CA (<LocalHostName>)`, 10-year validity, `basicConstraints
  CA:TRUE`, `keyUsage keyCertSign, cRLSign`. Generated once. The private key never leaves the Mac.
- **Server cert**: ECDSA P-256, 825-day validity (the iOS maximum for user-installed roots),
  `extendedKeyUsage serverAuth`, SAN DNS names: `<LocalHostName>.local`, `<LocalHostName>`,
  `localhost`; SAN IPs: `127.0.0.1` and every non-loopback IPv4 present at generation time.
- Regenerated automatically when: missing, expiring within 30 days, hostname changed, or the current
  LAN IPv4 set is not a subset of the SAN. Regeneration of the server cert never touches the CA, so
  the phone's trust survives.
- Files written with mode 0600 in `certs/`.
- `cert_mode` in `pointer.json`: `auto` (above) or `external` (use `certs/server.crt` and
  `certs/server.key` as provided by the user, never regenerate, skip CA generation and the CA QR).

### 4.8 Pairing and authentication

- A **pairing token** is 16 random bytes (base64url), valid 10 minutes, single use. Minted by the
  setup page load or `phice pair-token`. Only one outstanding at a time (newest replaces). Its
  SHA-256 hash and expiry are persisted to `pair.json` (mode 0600), because `phice pair-token`
  runs in a different process from the menu-bar app and an in-memory token would be invisible to it.
- The phone URL is `https://<host>.local:8443/?pair=<token>`. The page sends it in `hello`. The Mac
  validates, mints a **device token** (32 random bytes, base64url), stores `{token_hash, name,
  created, last_seen}` in `devices.json` (SHA-256 of token, never the token itself), and returns it
  in `welcome`. The page stores it in `localStorage` and strips `?pair` from the URL.
- Every subsequent `hello` carries the device token. Comparison is constant-time against hashes.
- A `hello` with neither a valid pairing token nor a known device token gets `err unpaired` and the
  socket closes (code 4003).
- `Origin` header must equal `https://<host>.local:8443` or `https://<any SAN name>:8443`; otherwise
  the upgrade is refused.
- Only one phone at a time: a new authenticated connection replaces the previous one, which is closed
  with code 4001 `replaced`. The engine resets on replacement.
- "Revoke all paired devices" truncates `devices.json` and closes the current connection.

### 4.9 Accessibility

- On launch call `AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True})` once.
- Poll `AXIsProcessTrusted()` every 3 s; update icon and status.
- While untrusted, the engine still runs but the backend is a no-op logger, so the page shows a
  "Mac needs Accessibility permission" state message.
- Menu item opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- Note for README: when launched by launchd the grant attaches to the Python interpreter binary (the
  `uv`-managed one the venv points to). It persists across app updates as long as that interpreter
  stays the same. When run from a terminal, the grant attaches to the terminal app instead.

### 4.10 Launch agent

- Label `com.phice.agent`. `ProgramArguments`: `[<venv>/bin/python, -m, phice, run]`.
  `RunAtLoad: true`, `KeepAlive: false` (Quit stays quit until next login). Stdout/stderr to
  `logs/launchd.out.log` / `launchd.err.log`. `EnvironmentVariables.PATH` includes `/usr/bin:/bin`.
- `install` writes the plist then `launchctl bootstrap gui/<uid> <plist>` — starts immediately, no
  restart needed. `uninstall` runs `launchctl bootout gui/<uid>/com.phice.agent` then removes it.
- Menu "Launch at login" toggle only adds/removes the plist file (affects next login).

### 4.11 Cursor backend

`CursorBackend` protocol (all coordinates in Quartz global space: origin top-left of main display,
y grows downward):

```
get_position() -> (x, y)
move_to(x, y)                         # kCGEventMouseMoved
drag_to(x, y, button)                 # kCGEventLeft/RightMouseDragged
button_down(button, x, y, click_count)
button_up(button, x, y, click_count)
scroll(dy_px)                         # pixel units, continuous flag set
displays() -> list[Rect]
```

Quartz implementation details that must be honored:

- Post to `kCGHIDEventTap`.
- While a button is held, motion must be posted as *dragged* events, never *moved*.
- `kCGMouseEventClickState` must be set to 1, 2, 3 for single/double/triple clicks, otherwise macOS
  never recognizes double-clicks. The engine computes click count (same button, within
  `double_click_s`, within 6 px).
- Scroll: `CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitPixel, 1, dy)` with
  `kCGScrollWheelEventIsContinuous = 1` for trackpad-like smoothness.
- Position read via `CGEventGetLocation(CGEventCreate(None))`.
- Displays via `CGGetActiveDisplayList` + `CGDisplayBounds`.

`FakeCursor` implements the same protocol in memory and records every call (used by tests, the
replay tool, and `--backend fake`).

### 4.12 Recorder

When enabled, every received text frame is appended to `sessions/<timestamp>.jsonl` as
`{"rx": <monotonic seconds>, "raw": <frame>}`. Used by `tools/replay.py`.

The `hello` frame is **never** recorded raw, because it carries a token. A scrubbed marker
(`{"t":"hello","ver":1,"name":...}`) is written in its place, which also gives `replay.py` the
session boundary it needs: a recording can span several connections and each restarts `seq` at 1.

### 4.13 Logging

`logging` with a rotating file handler (1 MB × 3) at INFO; DEBUG via `PHICE_DEBUG=1`. Never log
tokens.

## 5. Pointer engine (pure, no I/O)

`engine.py` contains `PointerEngine(config, backend, clock)`. It has exactly two entry points:
`handle(packet: SensorPacket)` and `tick(now: float)`. Everything is deterministic given inputs and
the injected clock, so it is fully unit-testable with `FakeCursor` and a fake clock.

`tick` must also be driven by a **periodic task in the server** (50 Hz while active, 5 Hz otherwise),
not only from `handle`. Pending clicks, the recenter countdown and the packet timeout are all
time-based: a phone that stops transmitting mid-press would otherwise leave a button held forever.

### 5.1 Orientation → aim

Inputs are the W3C DeviceOrientation angles alpha (Z), beta (X′), gamma (Y″) in degrees.

```
Rz(a) = [[ca,-sa,0],[sa,ca,0],[0,0,1]]
Rx(b) = [[1,0,0],[0,cb,-sb],[0,sb,cb]]
Ry(g) = [[cg,0,sg],[0,1,0],[-sg,0,cg]]
R     = Rz(a) · Rx(b) · Ry(g)
p     = R · (0, 1, 0)ᵀ           # the phone's "top" axis, in the room frame
yaw   = atan2(p.x, p.y)          # degrees, positive = turning right
pitch = asin(p.z)                # degrees, positive = top edge raised
```

Because `Ry(g)` acts last about the very axis we project, gamma (roll around the phone's long axis)
cancels exactly: `p = Rz(a)·Rx(b)·ŷ`. The implementation still computes the full product for
clarity; a property test asserts yaw/pitch are invariant under random gamma.

Yaw is unwrapped into a continuous value (`yaw_cont += wrap180(yaw − yaw_prev)`).

### 5.2 Filtering

- **One Euro filter** (Casiez et al. 2012) applied independently to `yaw_cont` and `pitch`, using
  packet timestamps for `dt`. Defaults: `min_cutoff 1.0`, `beta 0.02`, `d_cutoff 1.0`.
- **Deadzone**: if the rotation-rate magnitude from the packet is below `deadzone_dps`, the frame's
  delta is discarded (previous filtered value is set to current; nothing accumulates).
- Filters reset on power-on, on recenter snap, and when a gap > 250 ms occurs between packets.

### 5.3 Mapping and clamping

```
dx = (yawf − yawf_prev) · gain_x_px_per_deg
dy = −(pitchf − pitchf_prev) · gain_y_px_per_deg · (−1 if invert_y else 1)
base   = backend.get_position()            # live cursor: trackpad and phone coexist
target = base + (dx, dy) + fractional carry
target = clamp(target)                     # inside any display → keep; else clamp to the display
                                           # currently containing the cursor
```

Using the live position as the base makes **edge drag** automatic: overshoot beyond an edge is simply
discarded, so turning back moves the cursor immediately. Fractional remainders carry over so very slow
motion is not lost. An optional acceleration curve exists (`accel.enabled`, default false):
`mult = clip(1 + k·max(0, speed_dps − threshold_dps), 1, max_mult)`.

While frozen (§5.5), deltas are discarded the same way as the deadzone.

### 5.4 Session state machine

| State | Meaning |
|---|---|
| `DISCONNECTED` | No authenticated socket. |
| `OFF` | Connected; motion ignored; page streams at idle rate. |
| `ON` | Motion drives the cursor; buttons active. |
| `RECENTER_HOLD` | Left+right chord detected; cursor frozen; counting to `recenter_hold_ms`. |
| `RECENTER_HELD` | Snap done; motion live; clicks suppressed until all buttons are up. |

Transitions:

- `power` button rising edge: `OFF → ON` (reference = current angles; cursor untouched) or
  `ON/RECENTER_* → OFF`.
- Auto-activate (config, default off): `OFF → ON` after leaving the rest pose for `pickup_ms`.
- Auto-deactivate (default on): `ON → OFF` after `rest_seconds` in the rest pose and still.
- Packet timeout (`timeout_ms`, 500) while ON, socket close, sequence regression, or kill switch:
  `→ OFF` (or `DISCONNECTED`), always releasing held buttons first.
- Every transition out of `ON`/`RECENTER_*` releases any held mouse button.

### 5.5 Buttons, chord, freeze, drag, scroll

Per-button state: `up | pending(press_t) | down`.

- **Press** (rising edge from packet `b` or an increment of counter `c`): mark `pending`, set
  `frozen_until = now + freeze_ms_on_touch`.
- **Chord**: if left and right are both `pending` and their press times differ by ≤
  `chord_window_ms` → enter `RECENTER_HOLD` (no mouse events are ever sent for these presses).
- **Pending expiry**: a `pending` button older than `chord_window_ms` with no chord → send
  `button_down` at the current (frozen) cursor position; state `down`.
- **Short tap**: release while `pending` → send `button_down` then `button_up` immediately.
- **Release** while `down` → `button_up`; `frozen_until = now + freeze_ms_on_release`.
- **Missed tap**: counter `c` increased but `b` shows up → treat as a short tap.
- **Drag**: while any button is `down`, motion posts `drag_to` with that button.
- **Double-click**: `click_count` increments if the previous click of the same button was within
  `double_click_s` and 6 px; else resets to 1. Capped at 3.
- **RECENTER_HOLD**: cursor frozen. If either button releases before `recenter_hold_ms` → cancel;
  no events; state `ON`. When the hold completes → move cursor to the center of the display containing
  it, reset filters and reference, state `RECENTER_HELD`.
- **RECENTER_HELD**: motion live, no clicks. When all buttons are up → `ON`.
- **Scroll strip**: while touched the cursor is frozen. Each packet's `sd` (CSS px since last packet)
  becomes `sd · scroll_gain · (1 if scroll_natural else −1)` pixels, with fractional carry, posted
  via `scroll`.
- **Clutch** role: while held, cursor frozen.
- **Recenter** role (optional dedicated button): press → immediate snap as above, then `ON`.
- **Power** role: rising edge toggles as in §5.4. Power presses never generate mouse events.

### 5.6 Rest and pickup detection

- Rest pose: `|beta| < rest_tilt_deg` and `|gamma| < rest_tilt_deg` (phone lying face-up).
- Still: rotation-rate magnitude `< rest_rate_dps`.
- Rest = rest pose ∧ still continuously for `rest_seconds`.
- Pickup = not rest pose continuously for `pickup_ms`.

### 5.7 Safety invariants

- No mouse button is ever left down when the state is not `ON`/`RECENTER_HELD`.
- The engine never moves the cursor while `OFF`, `DISCONNECTED`, or when the kill switch is off.
- Out-of-order or duplicate packets (`seq` ≤ last) are dropped.

## 6. Phone page

### 6.1 Files

- Package: `web/index.html`, `web/app.js`. Vanilla HTML/CSS/JS, no build step, no framework.
- Config dir (user-editable, served live): `theme.css`, `layout.json`, `assets/`.
- `app.js` contains **no colors, sizes, fonts, or labels**. All visuals come from the three
  config sources. The HTML skeleton is: header (logo image + status text), pad container, overlays
  (start screen, denied screen, landscape screen, disconnected banner), and the hidden haptic switch.

### 6.2 Startup flow

1. Page loads; shows the Start overlay (required: Safari only grants motion access from a tap).
2. Tap Start → `DeviceMotionEvent.requestPermission()` and `DeviceOrientationEvent.requestPermission()`
   (guarded for browsers where they do not exist) → on `granted`, request Screen Wake Lock, open the
   WebSocket, send `hello`.
3. If the URL has `?pair=`, `hello` includes it; on `welcome` store the device token in
   `localStorage` and `history.replaceState` the param away.
4. Fetch `/layout.json`, render the pad. Apply `state` messages.
5. On `denied`: show the recovery overlay (Settings → Safari → clear website data for this site, or
   Settings → Safari → Motion & Orientation Access).

### 6.3 Rendering and theming rules

- The pad is the viewport minus safe-area insets minus `--pad-bottom-margin` (theme variable, default
  12 %) so no button touches the Home-indicator swipe zone.
- Each layout button becomes
  `<div class="btn role-<role> id-<id>" data-id data-role style="left:X%;top:Y%;width:W%;height:H%">`
  containing either an `<img src="assets/…">` (if `icon` set) or a `<span class="label">`.
- Pressed state: `data-pressed="1"`. Page state on `<body>`: `data-state="off|on|hold|held|disconnected|nopermission"`.
- Recenter progress: `--recenter-progress` CSS variable on `<body>` (0–1), so the theme can draw a ring
  or bar any way it likes.
- Theme variables (all defined in `theme.css` with defaults): `--bg-off`, `--bg-on`, `--fg`,
  `--accent`, `--btn-bg`, `--btn-bg-pressed`, `--btn-fg`, `--btn-border`, `--btn-radius`,
  `--btn-shadow`, `--scroll-bg`, `--scroll-thumb`, `--font`, `--label-size`, `--header-display`,
  `--logo-height`, `--pad-bottom-margin`. Role and id classes allow per-button overrides.
- Off state renders pure black background by default (OLED pixels off).
- The page re-fetches `/theme.css?v=<ts>` on `theme_changed` and re-renders on `layout`.

### 6.4 Touch handling

- Listeners on the pad container: `touchstart`, `touchmove`, `touchend`, `touchcancel`, all
  `{passive:false}` with `preventDefault()`.
- Each touch is hit-tested against button rects at `touchstart` and bound to that button by
  `identifier` until it ends. Multiple simultaneous touches are supported (left + right chord).
- Scroll-role buttons track per-touch vertical movement; the delta since the last send accumulates
  into `sd`.
- CSS: `touch-action: none; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none;`
  and viewport `user-scalable=no, viewport-fit=cover`.
- Any button state change triggers an immediate packet send (in addition to the sensor cadence).

### 6.5 Sensor sampling and send policy

- Keep the latest `deviceorientation` (alpha, beta, gamma) and `devicemotion` (rotationRate,
  accelerationIncludingGravity). Send one packet per `devicemotion` event while ON (≈60 Hz).
- While OFF: the Mac's `state.idle_hz` dictates. `0` → sensor listeners removed entirely and only a
  `ping` every 5 s; `>0` → listeners kept and packets sent at that rate (used when auto-activate is on;
  default 10 Hz then).
- Packets carry a monotonically increasing `seq` and the event timestamp.

### 6.6 Haptics

Safari has no vibration API. The page uses the native switch quirk: a visually hidden
`<input type="checkbox" switch>` inside a `<label>`; on each button touch-down the page calls
`.click()` on it inside the touch handler. If the user's device produces no haptic, the fallback is to
render buttons as `<label for="haptic">` so the user's own tap toggles it. Both paths are behind
`ui.haptics` (`state` message, from `pointer.json`), default on. A "Test haptic" button on the Start
overlay lets the user verify quickly. Double tick on recenter snap.

### 6.7 Connection, visibility, orientation

- WebSocket URL is derived from `location.host` (`wss://<host>/ws`).
- Reconnect with backoff 0.5 s → 5 s; state banner while disconnected.
- `visibilitychange` → hidden: send `{"t":"bye"}`, stop sensors, release wake lock. Visible: reconnect,
  re-request wake lock, re-request permissions if needed.
- Safari cannot lock orientation; a landscape overlay asks to rotate back and the pad is inert.
- `apple-mobile-web-app-capable`, `apple-mobile-web-app-status-bar-style=black-translucent`,
  `apple-mobile-web-app-title`, and an `apple-touch-icon` served from `assets/` (so the Home Screen
  icon is user-replaceable too).

### 6.8 Lightweight rules

- No animation loop; DOM updates only on state changes. Recenter ring uses a CSS transition driven by
  the progress variable updated at ≤10 Hz.
- Wake lock policy `ui.keep_awake`: `always` (default; screen stays on while the phone rests, page is
  pure black) or `on_only`.
- Sensor listeners are removed entirely when not needed (see §6.5).

## 7. Protocol

JSON text frames over `/ws`. Max frame 2 KB. Client rate limit 200 frames/s (excess closes 4008).

### Phone → Mac

```
{"t":"hello","ver":1,"pair":"<pairing token>" | "token":"<device token>","name":"iPhone","ua":"..."}
{"t":"s","seq":123,"ts":1234.567,
 "o":[alpha,beta,gamma],            # degrees; alpha may be null before first orientation event
 "rr":[x,y,z],                      # deg/s (rotationRate)
 "g":[x,y,z],                       # m/s² (accelerationIncludingGravity)
 "b":{"left":0|1,"right":0|1,"scroll":0|1,"power":0|1,...},   # every layout button id
 "c":{"left":n,"right":n,"power":n,...},                      # press counters (monotonic)
 "sd":-14.5}                        # scroll px since last packet
{"t":"ping"}
{"t":"bye"}
```

### Mac → Phone

```
{"t":"welcome","device_token":"..."}                    # only after successful pairing
{"t":"state","conn":true,"power":true|false,"phase":"off|on|hold|held","recenter":0.0-1.0,
 "idle_hz":0|10,"accessibility":true|false,"ui":{"haptics":true,"keep_awake":"always"}}
{"t":"layout", ...contents of layout.json...}
{"t":"theme_changed"}
{"t":"err","code":"unpaired|busy|bad_packet","msg":"..."}
{"t":"pong"}
```

Validation on the Mac (system boundary): types and ranges (`o` alpha [0,360) or null, beta
[−180,180], gamma [−90,90]; `rr` |v| ≤ 5000; `g` |v| ≤ 50; `b` values 0/1; `c` non-negative ints;
`sd` |v| ≤ 10000; `seq` positive int). Invalid packets are dropped and counted; 20 in a row closes
the socket.

## 8. Configuration files

### 8.1 `pointer.json` (defaults)

```json
{
  "version": 1,
  "gain_x_px_per_deg": 25.0,
  "gain_y_px_per_deg": 25.0,
  "invert_y": false,
  "one_euro": {"min_cutoff": 1.0, "beta": 0.02, "d_cutoff": 1.0},
  "deadzone_dps": 0.5,
  "accel": {"enabled": false, "threshold_dps": 40.0, "k": 0.01, "max_mult": 3.0},
  "freeze_ms_on_touch": 120,
  "freeze_ms_on_release": 60,
  "chord_window_ms": 50,
  "recenter_hold_ms": 1000,
  "double_click_s": 0.5,
  "scroll_gain": 1.5,
  "scroll_natural": true,
  "auto_activate": false,
  "auto_deactivate": true,
  "pickup_ms": 300,
  "rest_seconds": 1.0,
  "rest_tilt_deg": 15.0,
  "rest_rate_dps": 8.0,
  "idle_hz_when_auto_activate": 10,
  "timeout_ms": 500,
  "cert_mode": "auto",
  "ui": {"haptics": true, "keep_awake": "always"}
}
```

Validation: every field range-checked on load; unknown keys warn; an invalid file keeps the previous
good config and logs the error (never crashes the app).

### 8.2 `layout.json` (default)

```json
{
  "version": 1,
  "buttons": [
    {"id": "power",  "role": "power",  "x": 32, "y": 3,  "w": 36, "h": 9,  "label": "POWER"},
    {"id": "left",   "role": "left",   "x": 3,  "y": 50, "w": 42, "h": 46, "label": "L"},
    {"id": "scroll", "role": "scroll", "x": 46, "y": 48, "w": 8,  "h": 50, "label": ""},
    {"id": "right",  "role": "right",  "x": 55, "y": 50, "w": 42, "h": 46, "label": "R"}
  ]
}
```

Fields: `id` (unique, `[a-z0-9_-]+`), `role` ∈ {`left`,`right`,`scroll`,`power`,`clutch`,`recenter`},
`x y w h` percent of the pad (0–100, `x+w ≤ 100`, `y+h ≤ 100`), optional `label`, optional `icon`
(path under `assets/`), optional `class` (extra CSS classes). Exactly one `power`, at most one each of
`left`, `right`, `scroll`. Invalid layouts are rejected with a logged reason and the last good layout
stays in effect.

### 8.3 `theme.css`

Defines every variable in §6.3 plus base rules for `.btn`, `.role-scroll`, `header`, overlays. Users
edit freely; the page only depends on class names and variables, never on specific values.

### 8.4 `assets/`

`logo.svg` (page header), `apple-touch-icon.png` (Home Screen icon), `icons/*.svg` (optional button
icons), `menubar/{warn,disconnected,off,on}.png` (Mac status icons, black-on-transparent templates,
36×36 px recommended).

### 8.5 Hot reload

A 1 Hz watcher compares `mtime` of `pointer.json`, `layout.json`, `theme.css`. Changes apply live:
pointer config swaps atomically in the engine; layout is re-validated and pushed as a `layout`
message; theme triggers `theme_changed`. Asset changes need only a page reload.

## 9. Security

- TLS everywhere on the phone path; local CA private key stays on the Mac with mode 0600.
- Nothing can move the cursor without a device token that was issued from a pairing token minted on
  the Mac itself (setup page is loopback-only; CLI requires local shell access).
- Device tokens are stored hashed; comparisons are constant-time.
- Origin check on WebSocket upgrade; frame size and rate limits; strict packet validation.
- Static file serving is whitelisted by extension and confined to the assets directory.
- Kill switch in the menu; automatic release of all buttons on any fault.
- Nothing is ever sent to the internet.

## 10. Performance and battery budget

Targets, with figures measured on a reference build (M-series MacBook Air, macOS 26.6):

| Item | Target | Measured |
|---|---|---|
| Mac CPU, idle (phone off or disconnected) | < 1 % | 0.1 % |
| Mac CPU, pointer on at 60 Hz | < 3 % | 2.7 % (5.4 % at a forced 120 Hz) |
| Mac RSS | < 80 MB | 43 MB |
| Sensor-to-cursor latency on LAN | < 35 ms typical | not yet measured on-device |
| Phone network | ≈ 12 KB/s while on; ~0 while off | as designed |
| Phone CPU while off with auto-activate off | sensors off, one ping per 5 s | as designed |

## 11. Testing strategy and tooling

### Unit tests (`tests/`, pytest)

- `test_orientation.py`: rotation matrix vs. hand-computed cases; yaw/pitch signs; **property test**:
  random alpha/beta with 50 random gammas → identical yaw/pitch (tolerance 1e-9); yaw unwrap across
  ±180.
- `test_filters.py`: One Euro step response, smoothing at low speed, low lag at high speed; deadzone.
- `test_engine.py` with `FakeCursor` and fake clock: power on keeps cursor; motion maps with correct
  sign and gain; freeze on touch; short tap = down+up; pending → down after chord window; chord →
  no events; hold < 1 s → cancel; hold ≥ 1 s → snap to display center and clicks suppressed until
  release; drag posts dragged events; double-click count; scroll natural/inverted; clutch; edge clamp
  and edge-drag behavior; multi-display crossing; timeout releases buttons; auto-deactivate; auto-
  activate; sequence regression dropped; kill switch.
- `test_protocol.py`: parse/validate every message, reject out-of-range, size, counters.
- `test_config.py`: defaults load; invalid values rejected while keeping last good; layout
  validation; hot-reload detection.
- `test_pairing.py`: token mint/expiry/single-use; device token hashing; constant-time compare.
- `test_certs.py`: CA + server cert generation; SANs include hostname; regeneration triggers.
- `test_server.py` (asyncio, real TLS on ephemeral ports with a temp config dir): static routes,
  origin check, unpaired rejection, pairing flow, replacement of an older connection, `state` and
  `layout` push, fake backend `/debug/cursor` reflects motion.

### Tools

- `tools/fake_phone.py`: connects over real TLS (trusting `certs/ca.crt`), pairs with a token from
  `phice pair-token`, and plays patterns: `still`, `sweep` (sine on yaw), `square`, `click`,
  `doubleclick`, `drag`, `chord` (recenter), `scroll`, `replay <file>`. With `--assert` it reads
  `/debug/cursor` (fake backend) or Quartz (real backend, if trusted) and checks the expected effect.
- `tools/replay.py`: runs a recorded session through the engine offline and prints path stats
  (total travel, jitter while still, click/drag counts) so tuning can be compared numerically.

### What the agent can and cannot verify

The agent verifies everything above plus a manual smoke run of the real Mac app with the fake phone.
Only the human can verify: sensor sign conventions on a real iPhone, haptics, feel/tuning, CA install
UX. §13 is the human checklist.

## 12. Setup and first-run UX (README)

1. Install `uv` if missing, then `uv sync` and `uv run phice install`. The menu bar icon appears
   immediately; no reboot.
2. Click the icon → **Grant Accessibility…** and enable Phice's interpreter in the list.
3. Click **Show setup page**. On the iPhone, scan **QR 1** (CA install): Safari asks to allow a
   profile download → Settings → Profile Downloaded → Install → then General → About → Certificate
   Trust Settings → enable full trust for "Phice Local CA". One time only.
4. Scan **QR 2** (pairing URL). Tap **Start**, allow motion access. Optionally use Share → Add to
   Home Screen, open it from there, and scan QR 2 again from inside it (Home Screen apps keep
   separate storage).
5. Aim at the cursor, tap POWER. Hold L+R for one second to recenter.
6. Tune by editing `pointer.json`; edit `layout.json`, `theme.css`, `assets/` to change the look.

Alternative without CA install: place any cert/key pair Safari already trusts (e.g. from Tailscale)
at `certs/server.crt` / `certs/server.key` and set `"cert_mode": "external"` in `pointer.json`.

## 13. Human verification checklist

- [ ] Turning the phone right moves the cursor right; raising the top edge moves it up. If not,
      flip `invert_y` / note yaw sign for a one-line fix in `orientation.py`.
- [ ] Rolling the phone about its long axis does not move the cursor.
- [ ] POWER on: cursor does not jump. POWER off: cursor stops.
- [ ] L+R held 1 s: cursor snaps to center; no click fires; motion works while still holding.
- [ ] Tap = click; hold and move = drag; double-tap selects a word in a text field.
- [ ] Scroll strip scrolls a web page in the expected direction.
- [ ] Haptic tick on press (report which path worked: `.click()` or label fallback).
- [ ] Lay the phone flat for a second → pointer turns off automatically.
- [ ] Kill Wi-Fi mid-drag → no stuck button on the Mac.
- [ ] Edit `theme.css` color → page updates without reload; edit `layout.json` → buttons move.

## 14. After the MVP

Native Swift Mac app with the same protocol; WebRTC data channel for UDP-like transport; camera
glide mode (Phase 2); optional acceleration curve tuning; middle click role.
