# Phice

Turn an iPhone into a Wii-remote-style air mouse for macOS.

Point the phone at your screen and the cursor follows. Tap to click, hold and move
to drag, slide the centre strip to scroll, hold the power button to snap back to
the middle.

**There is no iOS app, and there never will be.** The phone runs a plain web page
your Mac serves — no App Store, no sideloading, and **no Apple Developer account**,
not even the free tier. Nothing is installed on the phone beyond an optional Home
Screen shortcut.

Point it at the cursor, press any button, and it starts tracking from there. Set the
phone down and it turns itself off.

```
iPhone (Safari)                          Mac (Phice.app)
────────────────                         ────────────────────────
CoreMotion ──┐                           validate the packet
touch      ──┼── JSON, 60 Hz ──────────► decide what should happen
             │   WebRTC or WebSocket     post a Quartz cursor event
             └─◄── layout + theme ─────── push config changes live
```

Every pointer decision happens on the Mac, in a pure engine with no I/O, driven by
an injected clock and a swappable cursor backend. That is why 225 tests run in
about fifteen seconds without a phone, a screen or a real cursor.

---

## Install on the Mac (once)

Download `Phice.app` and drag it to **Applications**. It is not notarized, so the
first launch needs **System Settings › Privacy & Security › Open Anyway** (on
macOS 15+ right-click → Open no longer works).

Opening it shows a small window with your pairing code, the link to open on the
phone, and live status. Close it and Phice keeps running in the menu bar; **open
the app again to bring the window back**. Grant it Accessibility, which is what
lets it move the cursor:

```bash
/Applications/Phice.app/Contents/MacOS/Phice grant
```

Approve the dialog, switch **Phice** on in **Privacy & Security › Accessibility**,
then start it at login:

```bash
/Applications/Phice.app/Contents/MacOS/Phice install
```

Remove it with `… Phice uninstall`, then drag the app to the Trash.

If the menu bar icon never appears, that is macOS, not Phice: new status items go
to the left of existing ones, and on a notched Mac with a full menu bar they land
behind the notch where nothing can click them. Opening the app again always brings
the window back, and `curl -s http://127.0.0.1:8080/debug/cursor` prints the full
status regardless.

### Building it yourself

```bash
git clone https://github.com/zupersun/phice.git
cd phice && uv sync
./packaging/create-signing-identity.sh   # once: stable signing identity
./packaging/build.sh                     # produces dist/Phice.app
```

The signing step matters. Without it the bundle is ad-hoc signed, and macOS then
ties your Accessibility permission to a hash that changes on every build — so each
rebuild silently revokes it while the entry still shows as switched on. Currently
arm64 only.

## Connect your phone

Open **[phice.vercel.app/app](https://phice.vercel.app/app)** on the iPhone, type
the six-character code from the Mac window, and tap **Start** to allow motion
access. That is the whole setup: no profile to install, no certificate to trust,
no account.

The two devices then talk directly to each other over WebRTC, which verifies the
peers by DTLS fingerprint — that is why no certificate is involved. It works
across different networks, including the phone on cellular and the Mac behind a
university or corporate firewall, because a relay carries the traffic when the two
cannot reach each other directly.

Use **Share › Add to Home Screen** and open it from there to run fullscreen with
no Safari chrome. The code is remembered, so reconnecting is one tap.

<details>
<summary><b>Running it without the hosted page</b> — offline, or if you would rather
not depend on a third party</summary>

Phice can serve the page from your Mac instead. Safari exposes motion sensors only
to a secure page, and a secure page cannot open an insecure WebSocket, so this path
needs a certificate the phone trusts. Set `transport` to `"tls"` in `pointer.json`.

**Tailscale — recommended.** Your Mac gets a real, publicly trusted Let's Encrypt
certificate, so there is nothing to install on the phone, and it still works when
the phone is on cellular.

1. `brew install --cask tailscale`, open it, sign in.
2. Enable HTTPS once for your tailnet:
   [login.tailscale.com/admin/dns](https://login.tailscale.com/admin/dns) ›
   **HTTPS Certificates** › **Enable**.
3. Install Tailscale on the iPhone and sign in with the same account.
4. `uv run phice tailscale`
5. Open `http://127.0.0.1:8080/setup` on the Mac and scan the QR code.

**Local certificate — same Wi-Fi only.** No accounts, but the phone must install a
certificate profile, and both devices must be on the same network with
client-to-client traffic allowed.

1. Open `http://127.0.0.1:8080/setup` on the Mac. It shows two QR codes.
2. Scan the **first**. Safari offers a configuration profile — allow it, then
   **Settings › Profile Downloaded › Install**.
3. **Settings › General › About › Certificate Trust Settings** — turn
   **Phice Local CA** on. Installing the profile is not enough on its own; this
   switch is what actually trusts it.
4. Scan the **second** QR code. The page opens with no warning.

If a QR does nothing, your network is blocking `.local` name lookups; the setup page
prints an IP address form underneath. If the page loads but stays black, open
`http://<your-mac-ip>:8080/check` on the phone — it loads over plain HTTP and tells
you whether the certificate is trusted.

Pairing is required either way: a pairing token is valid for ten minutes, single
use, and redeeming it issues a long-lived device token the page keeps. Without it,
nobody else can move your cursor.

It is the same page either way. The phone asks `/transport` which one it is on;
your Mac answers, and the hosted page does not, so there is one client and one
wire protocol behind both.

</details>

## Daily use

Open the page from the Home Screen. **Point the phone at the cursor and press any
button** — tracking starts from wherever the cursor already is, so nothing jumps.
That first press only wakes it; it does not click.

| Gesture | Result |
|---|---|
| Turn the phone right / left | Cursor moves right / left |
| Raise / lower the top edge | Cursor moves up / down |
| Roll the phone along its axis | Nothing — roll cancels out exactly |
| Tap the left pad | Left click |
| Tap the right pad | Right click |
| Hold the left pad and move | Drag |
| Double tap | Double click |
| Slide the centre strip | Scroll |
| **Hold** the power button | Snap the cursor to the centre of the display |
| **Tap** the power button | Pointer off |
| Set the phone down | Pointer off by itself |

The small button below the pads carries a status light: **red when idle, green
while driving the cursor**. Holding it brightens the whole surface as the recenter
completes, because your fingers cover the light at the moment it matters.

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
| `panel.css` | The Mac window: palette, the appearance switch, layout |
| `calibrate.css` | The calibration screen |
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
| `scroll_gain` | Displacement scrolling from raw finger travel. `0` by default: the strip is a rate control, and running both at once doubles the input. |
| `scroll_deadzone` | Dead band either side of the strip's centre, so a resting finger does not creep. |
| `scroll_min_px_per_s` | Floor speed for any deflection past the dead band, so a small nudge does something visible. |
| `scroll_rate_px_per_s` | Speed at the very ends of the strip. |
| `scroll_rate_expo` | How sharply speed grows with distance from the centre. Lower is more linear. |
| `scroll_natural` | Scroll direction. Flip it if scrolling feels backwards. |
| `auto_activate` | Turn the pointer on by itself when you pick the phone up. |
| `auto_deactivate` | Turn the pointer off by itself when you set the phone down. |
| `pickup_ms` | How long the phone must be raised before `auto_activate` fires. |
| `rest_seconds` | How long the phone must lie still before `auto_deactivate` fires. |
| `rest_tilt_deg` | How flat counts as "resting". |
| `rest_rate_dps` | How still counts as "resting". |
| `idle_hz_when_auto_activate` | Packet rate the phone uses while idle and waiting to be picked up. |
| `timeout_ms` | No packets for this long releases every button and powers off. |
| `transport` | `webrtc` (default) pairs by code through the hosted page. `tls` serves the page from your Mac instead. |
| `signaling_url` | Where the hosted page and its pairing letterbox live. |
| `cert_mode` | `tailscale` for a publicly trusted tailnet certificate (recommended), `auto` for the built-in certificate authority, `external` if you supply your own `certs/server.{crt,key}`. |
| `tailscale_host` | Set by `phice tailscale`. The MagicDNS name to serve on. |
| `mapping` | `absolute` (default) points the cursor where the phone points, anchored at the last recenter. `relative` integrates turn deltas like a trackpad in the air. |
| `ui.appearance` | `dark` or `light`, for the phone and the Mac window together. The switch in the Mac window writes this. |
| `ui.haptics` | Haptic tick on button press. Best-effort — see the note under Daily use. |
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

### Calibrate it

Sensitivity is not describable in words, so do not try. **Calibrate pointer…** in
the app window (or `uv run phice calibrate`) shows ten dots, one at a time. Point
the phone at each and hold still.

**There is no cursor during it, deliberately.** The obvious design — show a
target, let you drive the cursor onto it, measure the rotation you used — is
circular. At gain G, covering D pixels *requires* turning D/G degrees, so you
turn until the cursor arrives and the measurement comes back as D / (D/G) = G:
the setting it already had. What it really records is how you correct a cursor,
which is not how anyone points at a thing.

Pointing with no cursor measures the real quantity instead: how many pixels of
your screen one degree of wrist rotation covers, at the distance you actually sit
and in the grip you actually use. Nothing in that loop depends on the settings
being fitted, so the answer cannot echo them back. Tremor is measured the same
way, in degrees of phone rather than pixels of cursor.

It also switches `expo` off, and that is not an oversight: pointing is geometry,
and one degree covers the same distance wherever you point. A curve on top is a
preference about feel — turn it back up by hand if you want flicks amplified.

Nothing changes until you press **Use these settings**, and every aim is saved
next to the verdict in `sessions/calibration.json`, so a correction to the
fitting can be re-run against data you already gave it.

### By hand

Record once, then compare variants offline as often as you like:

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
uv run pytest -q        # unit tests
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

The phone streams orientation and touch state at 60 Hz. Every pointer decision —
mapping, filtering, clicks, recentering, safety — happens on the Mac in a pure,
unit-testable engine that drives a swappable cursor backend.

There is **one phone client**, `web/app/`, served both by Vercel and by your Mac
(`src/phice/web` is a symlink to it). It asks `/transport` which way it arrived and
opens either a WebRTC data channel or a WebSocket; everything either side of that
seam is common. There used to be two copies, and they drifted — the Mac's quietly
missed light and dark, haptics and the screen split, because every phone change had
to be made twice.

Roll cancels out algebraically rather than by approximation: the W3C rotation order
applies gamma last about the very axis the aim vector is projected from, so rolling the
phone is mathematically incapable of moving the cursor.

```
orientation.py     Euler angles -> aim vector -> yaw/pitch (roll-invariant)
filters.py         One Euro filter: smooth when still, responsive when fast
mapping.py         expo curve, yaw unwrapping, edge overshoot
protocol.py        wire format, validated at the system boundary
engine.py          all pointer behaviour; pure, no I/O
calibrate.py       trials and the fit; pure, no display needed
cursor_backend.py  Quartz event injection, plus a fake for tests
rtc.py             WebRTC data channel peer
webrtc_session.py  publish an offer under a code, serve whoever answers
server.py          TLS: page, assets, WebSocket, engine tick, recorder
setup_server.py    loopback HTTP: the routes
pages.py           the pages those routes serve
window.py          the Mac control panel window
```

Nothing in that list may point backwards up it.

## Licence

MIT.
