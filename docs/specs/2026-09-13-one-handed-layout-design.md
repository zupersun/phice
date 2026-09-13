# One-handed layout — design

Date: 2026-09-13
Status: approved

## Why

Most people hold a phone in one hand and reach the screen with that hand's thumb.
Phice's layout assumes two hands: the pads fill the top two-thirds of the screen,
which is the part a thumb gripping low cannot reach at all.

## What changes

Two named layouts, and a small move in the existing one.

| | power | pads |
|---|---|---|
| `standard` | `y 76`, `h 7` (was `y 68`) | unchanged, `y 2`–`64` |
| `one-handed` | `y 17`, `h 7` | `y 36`–`98` |

Exact geometry, in the percentages `layout.json` already uses:

```json
// standard.json
{"version": 1, "buttons": [
  {"id": "left",   "role": "left",   "x": 3,  "y": 2,  "w": 42, "h": 62, "label": ""},
  {"id": "scroll", "role": "scroll", "x": 46, "y": 2,  "w": 8,  "h": 62, "label": ""},
  {"id": "right",  "role": "right",  "x": 55, "y": 2,  "w": 42, "h": 62, "label": ""},
  {"id": "power",  "role": "power",  "x": 42, "y": 76, "w": 16, "h": 7,  "label": ""}
]}

// one-handed.json
{"version": 1, "buttons": [
  {"id": "power",  "role": "power",  "x": 42, "y": 17, "w": 16, "h": 7,  "label": ""},
  {"id": "left",   "role": "left",   "x": 3,  "y": 36, "w": 42, "h": 62, "label": ""},
  {"id": "scroll", "role": "scroll", "x": 46, "y": 36, "w": 8,  "h": 62, "label": ""},
  {"id": "right",  "role": "right",  "x": 55, "y": 36, "w": 42, "h": 62, "label": ""}
]}
```

One-handed is the exact vertical mirror of standard: every button flipped about
the middle of the pad, `y -> 100 - (y + h)`, keeping its size and its horizontal
place. So the pads reach the bottom edge with the same margin they have at the
top the other way up, and power sits directly above them exactly as it sits
directly below them in standard. A test pins that as arithmetic rather than as
four sets of coordinates, so the two cannot drift apart.

Power ends up above the pads rather than below for two reasons pointing the same
way: it is the one control that must never be pressed by accident, and a thumb
gripping low reaches the bottom of the screen most easily and the top least.

The layout is left-right symmetric, so it works in either hand. There is no
handedness setting to build.

## Where layouts live

Presets are seeded into `~/Library/Application Support/Phice/layouts/` as
`standard.json` and `one-handed.json`, user-owned and editable like every other
file in that directory, and never overwritten once they exist.

`pointer.json` gains `ui.layout`, naming the active preset by filename stem.

Resolution order, and it must be exactly this:

1. `ui.layout` names a file in `layouts/` that parses → use it.
2. `ui.layout` is absent or empty → use `layout.json`, as now.
3. `ui.layout` names something missing or invalid → log the reason, fall back to
   `layout.json`.

Rule 2 is what keeps every existing install working untouched, including anyone
who has already edited `layout.json`. Rule 3 exists because a layout that fails
to load leaves the phone with no buttons at all, which is indistinguishable from
a broken app; falling back to something is always better than rendering nothing.

Switching away from a preset and back must not lose edits made to it. That falls
out of the design: the presets are separate files and switching only changes a
name in `pointer.json`.

## How it is switched

A control in the Mac control panel window, beside the appearance switch, writing
`ui.layout` through the same path as the appearance setting: persist to
`pointer.json`, then reload, which pushes the new layout to the phone.

The phone requires no changes. It already renders whatever layout arrives and the
Mac already pushes layouts when config changes.

## Out of scope

- A switch on the phone itself. It needs a settings screen the phone does not
  have, and this is a choice made once rather than during use.
- A handedness option: the layout is symmetric.
- Per-app or automatic switching.

## Testing

The engine maps button *roles*, not positions, so it is indifferent to this
change; the risk is entirely in config plumbing. Tests must cover:

- Both shipped presets parse and pass layout validation.
- `ui.layout: "one-handed"` selects that preset.
- `ui.layout` absent falls back to `layout.json`.
- `ui.layout` naming a missing or malformed file falls back to `layout.json`
  rather than leaving the phone with no buttons, and says why in the log.
- `Paths.ensure()` seeds both presets and never overwrites an edited one.
- The power button sits lower in `standard` than it used to, pinned as a number
  so a later tidy-up cannot quietly undo the ergonomic change.
