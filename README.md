<div align="center">

![](docs/logo.svg)

# Phice

Use an iPhone as an air mouse for macOS.<br>
Point the phone, the cursor follows.

[![Download Phice for Mac](https://img.shields.io/badge/Download-Phice%20for%20Mac-111827?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/zupersun/phice/releases/latest/download/Phice.dmg)

</div>

The phone runs a web page, not an app. It streams orientation and touch over
WebRTC; the Mac decides everything and drives the cursor.

## Setup

1. Drag **Phice** to Applications, then open it and grant Accessibility.
2. It runs in the background. Turn it on from the menu bar icon, or **Turn on**
   in its window.
3. Open <https://phice.vercel.app/app> on the phone, enter the code, tap Start.

Requires macOS 13 or later on Apple silicon. Phice is signed but not notarized,
so the first launch needs Privacy & Security › **Open Anyway**.

## Controls

| | |
|---|---|
| Turn the phone | Cursor left / right |
| Tilt the top edge | Cursor up / down |
| Tap a pad | Left / right click |
| Hold the left pad and move | Drag |
| Slide the centre strip | Scroll, faster further from the middle |
| Tap the power button | Pointer off |
| Hold the power button | Recentre the cursor |

Rolling the phone does nothing. Face-down switches the pointer off.

**Calibrate pointer…** measures how much screen one degree of wrist covers:
point at sixteen dots and hold. Colours, sizes and buttons are editable files —
see [docs/configuration.md](docs/configuration.md).

## Licence

MIT
