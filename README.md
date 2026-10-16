<div align="center">

![](docs/logo.svg)

# Phice

**Use an iPhone as an air mouse for macOS.**

[![Download Phice for Mac](https://img.shields.io/badge/Download-Phice%20for%20Mac-111827?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/zupersun/phice/releases/latest/download/Phice.dmg)

macOS 13 or later · Apple silicon

</div>

---

Point the phone at the screen and the cursor is already there, and it stays
there when your hand stops. The phone runs a web page, not an app: it streams
orientation and touch over WebRTC, and the Mac decides everything.

## Setup

1. Drag **Phice** to Applications, then open it and grant Accessibility.
2. It runs in the background. Turn it on from the menu bar icon, or **Turn on**
   in its window.
3. Open <https://phice.vercel.app/app> on the phone, enter the code, tap Start.

<details>
<summary>If macOS refuses to open it</summary>

Phice is code-signed, but not with a paid Apple Developer ID, so macOS
quarantines the download and blocks the first launch. Open it once from System
Settings › Privacy & Security › **Open Anyway**. It does not recur.
</details>

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
