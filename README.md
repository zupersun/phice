<div align="center">

# Phice

**Turn an iPhone into a pointer mouse for macOS.**

Point the phone at your screen and the cursor follows.
No iOS app, no App Store, no Apple Developer account.

<!-- Placeholder for the demo recording: the phone in one hand, the cursor
     following on screen. Replace the paragraph below with the video once shot. -->

Pick the phone up and point it at the screen. The cursor is already where you
aimed — not sliding after you like a trackpad catching up, but sitting on the
spot, and staying there when your hand stops. Turn your wrist two degrees and it
moves two degrees' worth. Tap the left pad to click. Set the phone face-down on
the desk and it switches itself off.

Setup is a six-character code typed into Safari. There is nothing to install on
the phone.

</div>

---

## What it does

| | |
|---|---|
| 🎯 **Points, not drags** | The cursor goes where the phone points, anchored where you last recentred — not integrated from deltas like a trackpad |
| 🌀 **Roll does nothing** | Rotating the phone about its own axis is *mathematically* incapable of moving the cursor, not merely filtered out |
| 📐 **Fitted to you** | Calibration measures how much screen one degree of your wrist covers, with no cursor on screen to steer |
| 🔌 **Any two networks** | Phone on cellular, Mac behind a campus firewall — WebRTC connects them directly, or over a relay when it must |
| 🎨 **Yours to restyle** | Every colour, size, button and position is a file you own. No rebuild, saves apply live |
| 🧪 **224 tests, 15 seconds** | The pointer engine is pure: an injected clock and a fake cursor, so behaviour is testable without a phone or a screen |

## Getting started

**1. Install the Mac app.** Download `Phice.app`, drag it to Applications, open it.
Not notarized, so the first launch needs **System Settings › Privacy & Security ›
Open Anyway**. Grant Accessibility when it asks — that is what lets it move the
cursor.

**2. Open the page on your phone.** The Mac window shows a six-character code and
a link:

```
https://phice.vercel.app/app
```

**3. Type the code, tap Start, allow motion access.** That is the whole setup —
no profile to install, no certificate to trust, no account.

Point at the cursor, press any button to begin. Set the phone down and it turns
itself off.

## Using it

| Gesture | Result |
|---|---|
| Turn the phone right / left | Cursor moves right / left |
| Raise / lower the top edge | Cursor moves up / down |
| Tap the left / right pad | Left / right click |
| Hold the left pad and move | Drag |
| Slide the centre strip | Scroll — further from the middle, faster |
| **Tap** the power button | Pointer off |
| **Hold** the power button | Snap the cursor to the centre |

The small button below the pads carries a status light: **red when idle, green
while driving the cursor**.

## Calibrate it

Sensitivity cannot be described in words, so don't try. **Calibrate pointer…** in
the app window shows sixteen dots. Point the phone at each and hold.

There is no cursor during it, deliberately. Show a target, let someone drive the
cursor onto it, and the measurement is circular: at gain *G*, covering *D* pixels
*requires* turning *D/G* degrees, so the answer comes back as the setting it
already had. Pointing with no cursor measures the real quantity — how many pixels
of your screen one degree of wrist rotation covers, at the distance you actually
sit.

## How it works

```
iPhone (Safari)                          Mac (Phice.app)
────────────────                         ────────────────────────
CoreMotion ──┐                           validate the packet
touch      ──┼── JSON, 60 Hz ──────────► decide what should happen
             │   WebRTC data channel     post a Quartz cursor event
             └─◄── layout + theme ─────── push config changes live
```

Every pointer decision happens on the Mac, in an engine with no I/O driven by an
injected clock and a swappable cursor backend. There is **one** phone client,
`web/app/`, served by Vercel. The two devices find each other through a
letterbox that holds one offer and one answer under the code; after that the
data channel is direct, or relayed when the networks allow nothing else.

Roll cancels algebraically rather than by approximation: the W3C rotation order
applies gamma last, about the very axis the aim vector is projected from.

## More

- **[Configuration](docs/configuration.md)** — every setting, what it controls,
  and where the files live
- **[Design notes](docs/specs/2026-09-11-phice-mvp-design.md)** — why the pointer
  works the way it does (historical)
- **[CLAUDE.md](CLAUDE.md)** — architecture, and the constraints that are not
  negotiable

```bash
uv run pytest -q        # 224 tests
uv run ruff check .     # lint
./packaging/build.sh    # produces dist/Phice.app
```

Exercise the whole system with no iPhone. The fake phone pairs through the same
letterbox a real one uses:

```bash
uv run phice --config-dir /tmp/e2e --http-port 18080 run --backend fake --headless &
uv run python tools/fake_phone.py --pattern sweep --check --http-port 18080
```

## Licence

MIT
