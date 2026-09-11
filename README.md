# Phice

Use an iPhone as a Wii-remote-style air mouse for macOS.

Hold the phone flat, point it at the screen, and the Mac cursor follows. Tap to click,
hold and move to drag, slide the centre strip to scroll, hold both buttons for a second
to snap back to the middle of the screen.

**There is no iOS app.** The phone runs a plain web page that your Mac serves over TLS
on your own network. Nothing is installed on the phone beyond an optional Home Screen
shortcut, nothing talks to the internet, and **you do not need an Apple Developer
account** — not even the free tier — because there is no app to sign or sideload.

The pointer never moves until you tap **POWER** on the phone. It is off by default,
off after a timeout, and off when you lay the phone flat.

---

## Install (once)

```bash
git clone https://github.com/zupersun/phice.git
cd phice
uv sync
uv run phice install
```

`install` writes a login agent and starts it immediately — the menu bar icon appears
within a second, with no restart and no logout.

Then grant Accessibility permission, which is what lets the app move the cursor:
click the menu bar icon and choose **Grant Accessibility…**, enable the entry that
appears in System Settings, and the icon changes from the warning glyph within
three seconds.

To remove it:

```bash
uv run phice uninstall
```

## Trust the certificate on the iPhone (once)

Safari only exposes motion sensors to a secure page, and a secure page cannot open an
insecure WebSocket, so TLS is not optional. Your Mac mints its own certificate
authority once and you trust it on the phone once. After that everything is offline
and automatic.

1. On the Mac, open the setup page: `uv run phice setup-url` and visit the printed
   `http://127.0.0.1:…/setup` address. It shows two QR codes.
2. Scan the **first** QR code with the iPhone camera. Safari downloads a profile.
   Install it in **Settings › General › VPN & Device Management**.
3. Turn it on in **Settings › General › About › Certificate Trust Settings** —
   enable full trust for **Phice Local CA**.
4. Scan the **second** QR code. The phone page opens with no certificate warning.
   Tap **Start** and allow motion access.

Optionally use **Share › Add to Home Screen**, then open it from there and scan the
pairing code once more from inside it. It runs fullscreen with no Safari chrome.

Pairing is required: a pairing token is valid for ten minutes, single use, and
redeeming it issues a long-lived device token the page keeps. Without it, nobody else
on the network can move your cursor.

## Daily use

Open the page from the Home Screen and tap **POWER**. The cursor is taken over exactly
where it already was — powering on never jumps it.

| Gesture | Result |
|---|---|
| Turn the phone right / left | Cursor moves right / left |
| Raise / lower the top edge | Cursor moves up / down |
| Roll the phone about its long axis | Nothing — roll is cancelled out exactly |
| Tap **L** | Left click |
| Tap **R** | Right click |
| Hold **L** and move | Drag |
| Double tap **L** | Double click |
| Slide the centre strip | Scroll |
| Hold **L** + **R** together for 1 s | Snap the cursor to the centre of the display |
| Tap **POWER** again | Pointer off |
| Lay the phone flat for a second | Pointer off by itself |

Losing Wi-Fi mid-drag releases every held button rather than leaving one stuck down.

## Where your settings live

Everything is a plain file in `~/Library/Application Support/Phice/`, and every one of
them hot-reloads within two seconds of saving. An invalid edit is rejected with a
logged reason and the previous good value stays in effect, so a stray comma never
kills the pointer mid-use.

| File | What it controls |
|---|---|
| `pointer.json` | All pointer feel and behaviour — the table below |
| `layout.json` | Which buttons exist on the phone, where, how big, what they do |
| `theme.css` | Every colour, size, font and radius on the phone page |
| `assets/` | Logo, menu-bar icons, Home Screen icon, button icons |
| `sessions/` | Recordings, for offline tuning |
| `logs/phice.log` | What the app is doing |

`uv run phice paths` prints the directory. `uv run phice reset-ui` restores
`layout.json`, `theme.css` and `assets/` from the packaged defaults, backing up
whatever was there.

### `pointer.json`

| Key | Meaning |
|---|---|
| `gain_x_px_per_deg` | Horizontal pixels of cursor travel per degree of turn. Raise for a faster pointer. |
| `gain_y_px_per_deg` | Vertical pixels per degree of tilt. |
| `invert_y` | Flip the vertical direction. Set this if raising the top edge moves the cursor down. |
| `one_euro.min_cutoff` | Baseline smoothing. Lower is smoother and laggier. |
| `one_euro.beta` | How much the filter opens up as you move faster. The jitter-versus-lag knob; tune this first. |
| `one_euro.d_cutoff` | Smoothing applied to the speed estimate itself. |
| `deadzone_dps` | Rotation rate below which motion is discarded, killing slow creep from a resting hand. |
| `accel.enabled` | Turn on pointer acceleration. |
| `accel.threshold_dps` | Speed above which acceleration starts applying. |
| `accel.k` | How aggressively acceleration ramps up past the threshold. |
| `accel.max_mult` | Hard ceiling on the acceleration multiplier. |
| `freeze_ms_on_touch` | How long the cursor holds still after you touch a button, so clicks land where you aimed. |
| `freeze_ms_on_release` | Same, after you lift off. |
| `chord_window_ms` | Two buttons pressed within this window count as a chord, not two clicks. |
| `recenter_hold_ms` | How long to hold both buttons before the cursor snaps to centre. |
| `double_click_s` | Maximum gap between taps still counted as a double click. |
| `scroll_gain` | Pixels scrolled per unit of finger travel on the strip. |
| `scroll_natural` | Scroll direction. Flip it if scrolling feels backwards. |
| `auto_activate` | Turn the pointer on by itself when you pick the phone up. |
| `auto_deactivate` | Turn the pointer off by itself when you set the phone down. |
| `pickup_ms` | How long the phone must be raised before `auto_activate` fires. |
| `rest_seconds` | How long the phone must lie still before `auto_deactivate` fires. |
| `rest_tilt_deg` | How flat counts as "resting". |
| `rest_rate_dps` | How still counts as "resting". |
| `idle_hz_when_auto_activate` | Packet rate the phone uses while idle and waiting to be picked up. |
| `timeout_ms` | No packets for this long releases every button and powers off. |
| `cert_mode` | `auto` for the built-in certificate authority, `external` if you supply your own (Tailscale, say). |
| `ui.haptics` | Haptic tick on button press. Best-effort; Safari has no vibration API. |
| `ui.keep_awake` | `always` or `on_only` — when to keep the phone screen awake. |

### `layout.json`

Positions are percentages of the pad, so a layout works on any screen size. Each button
takes an `id`, a `role`, `x`/`y`/`w`/`h`, and optionally a `label`, an `icon` path under
`assets/`, and a `class` for your own CSS.

| Role | Behaviour |
|---|---|
| `power` | Toggles the pointer on and off. **Exactly one is required.** |
| `left` | Left mouse button. At most one. |
| `right` | Right mouse button. At most one. |
| `scroll` | Vertical scroll strip. Freezes the cursor while in use. At most one. |
| `clutch` | Freezes the cursor while held, without clicking. Any number. |
| `recenter` | Snaps the cursor to the centre of the display immediately. Any number. |

## Tuning

Tuning is the part that needs a person. Record once, then compare variants offline as
often as you like without picking the phone up again:

1. Start **Record** from the menu bar icon, use the pointer for a minute, stop.
2. Compare tuning variants against that recording:

```bash
uv run python tools/replay.py ~/Library/Application\ Support/Phice/sessions/<file>.jsonl \
  --compare gain_x_px_per_deg=60
```

It reports cursor travel, jitter while the phone was still, click and drag counts, and
whether anything was left held. Recordings carry no pairing tokens and are safe to share.

Start with `gain_x_px_per_deg` / `gain_y_px_per_deg` for speed, `one_euro.beta` for the
jitter-versus-lag trade-off, and `freeze_ms_on_touch` if clicks land slightly off target.

## Development

```bash
uv run pytest -q        # 121 unit tests
uv run ruff check .     # lint
```

There is a fake phone that speaks the real protocol over a real TLS socket, so the whole
system can be exercised without an iPhone:

```bash
uv run phice --config-dir /tmp/phice-e2e --tls-port 18443 --http-port 18080 \
  run --backend fake --headless &
uv run python tools/fake_phone.py --pattern sweep --check \
  --config-dir /tmp/phice-e2e --tls-port 18443 --http-port 18080
```

Patterns: `still`, `roll`, `sweep`, `square`, `click`, `doubleclick`, `rightclick`,
`drag`, `chord`, `scroll`, `rest`. Drop `--backend fake` to drive the real cursor.

## How it works

The phone streams orientation and touch state at 60 Hz over a WebSocket. Every pointer
decision — mapping, filtering, clicks, recentering, safety — happens on the Mac in a
pure, unit-testable engine that drives a swappable cursor backend.

Roll cancels out algebraically rather than by approximation: the W3C rotation order
applies gamma last about the very axis the aim vector is projected from, so rolling the
phone is mathematically incapable of moving the cursor.

```
orientation.py   Euler angles -> aim vector -> yaw/pitch (roll-invariant)
filters.py       One Euro filter: smooth when still, responsive when fast
protocol.py      wire format, validated at the system boundary
engine.py        all pointer behaviour; pure, no I/O
cursor_backend.py  Quartz event injection, plus a fake for tests
server.py        TLS: page, assets, WebSocket, engine tick, recorder
setup_server.py  plain HTTP: CA download and QR setup (loopback only)
```

## Licence

MIT.
