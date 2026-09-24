# Configuring Phice

Every setting Phice has, what it does, and where it lives. Nothing here is
required reading -- the defaults are fitted by `phice calibrate` -- but every
one of these is editable and takes effect on save.

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
| `panel.css` | The Mac window: palette, the appearance switch, the pairing code's life bar, layout |
| `calibrate.css` | The calibration screen |
| `assets/` | Menu-bar icons and the logo |
| `sessions/` | Recordings, for offline tuning |
| `logs/phice.log` | What the app is doing |

Existing installs keep the `panel.css` they have. After an update that adds to it,
`uv run phice reset-ui` restores the packaged one (backing yours up).

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
| `signaling_url` | Where the hosted page and its pairing letterbox live. The Mac publishes its offer there under the code, and the phone fetches it. Must be `https://`. |
| `ice_servers` | Override the STUN/TURN servers both peers use. Empty by default: the letterbox hands out the same list to both sides, which is what lets them meet. |
| `mapping` | `absolute` (default) points the cursor where the phone points, anchored at the last recenter. `relative` integrates turn deltas like a trackpad in the air. |
| `ui.appearance` | `dark` or `light`, for the phone and the Mac window together. The switch in the Mac window writes this. |
| `ui.haptics` | Haptic tick on button press. Best-effort — see the note under Daily use. |
| `ui.keep_awake` | `always` or `on_only` — when to keep the phone screen awake. |

### `layout.json`

Positions are percentages of the pad, so a layout works on any screen size. Each button
takes an `id`, a `role`, `x`/`y`/`w`/`h`, and optionally a `label` and a `class` for your
own CSS. Put imagery in `theme.css` under that class: the page is hosted, so it cannot
fetch files from the Mac.

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
