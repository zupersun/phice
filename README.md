<div align="center">

![](docs/logo.svg)

# Phice

**Use an iPhone as an air mouse for macOS.**

[![Download Phice for Mac](https://img.shields.io/badge/Download-Phice%20for%20Mac-111827?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/zupersun/phice/releases/latest/download/Phice.dmg)

macOS 13 or later · Apple silicon

</div>

---

Point the phone at the screen and the cursor is already there, and it stays
there when your hand stops. Turn your wrist two degrees and it moves two
degrees' worth. The phone runs a web page, not an app: it streams orientation
and touch, and the Mac decides everything.

## Installing

**1. Download the disk image and drag Phice into Applications.**

Install it from Applications, not from the mounted image. macOS translocates an
app launched where it was downloaded, running it from a temporary path that
disappears, and Phice's login agent would then point at nothing.

**2. Open it and grant Accessibility.**

Phice is code-signed, but not with a paid Apple Developer ID. macOS therefore
quarantines the download and refuses the first launch; open it once from System
Settings › Privacy & Security › **Open Anyway**. Accessibility is the permission
that lets it move the cursor, and it only takes effect after Phice restarts.

**3. Turn it on.**

Phice runs in the background. Switch it on from the menu bar icon, or **Turn on**
in its window. Off, it mints no pairing code and talks to nothing.

**4. Pair the phone.**

The window shows a six-character code. Open
[phice.vercel.app/app](https://phice.vercel.app/app) on the iPhone, enter the
code, tap Start, and allow motion access. Nothing is installed on the phone.

## The pad

| | |
|---|---|
| Turn the phone | Cursor left / right |
| Tilt the top edge | Cursor up / down |
| Tap a pad | Left / right click |
| Hold the left pad and move | Drag |
| Slide the centre strip | Scroll, faster further from the middle |
| Tap the power button | Pointer off |
| Hold the power button | Recentre the cursor |

- **Roll does nothing.** Turning the phone about its own axis cannot move the
  cursor.
- **Face-down is off.** Set the phone down and the pointer stops.
- **The light reads the state.** Red when idle, green while driving the cursor.

## Calibrating

**Calibrate pointer…** shows sixteen dots. Point at each and hold, and it
measures how many pixels of your screen one degree of your wrist covers, at the
distance you actually sit.

There is no cursor on screen during it, deliberately. Steering a cursor onto a
target measures nothing: at a given gain, covering a distance *requires* turning
by exactly that distance over the gain, so the answer comes back as the setting
it already had.

## Making it yours

Every colour, size, button, label and position is a file you edit —
`theme.css` and `layout.json` in Phice's config folder. The page sets no
appearance of its own; it renders whatever the layout describes, and a save
applies live to a connected phone. See
[docs/configuration.md](docs/configuration.md), or run `phice paths` to find
them.

---

## How it reaches your Mac

| | |
|---|---|
| **Pairing** | The Mac publishes a WebRTC offer to a hosted letterbox under the six-character code; the phone fetches it and answers under the same code. The code expires and renews on its own. |
| **Transport** | One data channel carrying JSON at 60 Hz. Direct between the two devices where the networks allow it, relayed through Cloudflare TURN where they do not — a phone on cellular and a Mac behind a campus firewall still meet. |
| **Motion** | CoreMotion orientation, projected to an aim vector. Roll cancels algebraically rather than by filtering, because the W3C rotation order applies gamma last, about the very axis the aim is projected from. |
| **The cursor** | A pure engine on the Mac — an injected clock and a swappable backend, no I/O — posting Quartz events. Every pointer decision happens here, never on the phone. |
| **The page** | Static, served by Vercel. Safari exposes motion sensors only on a secure page, which is why it is hosted rather than served from the Mac: no certificate to trust, no profile to install, no account. |

## Building from source

```bash
uv run pytest -q          # the suite
./packaging/build.sh      # dist/Phice.app
```

Architecture, and the constraints that are not negotiable, are in
[CLAUDE.md](CLAUDE.md).

<div align="center">

MIT · © 2026 Jasper Sun

</div>
