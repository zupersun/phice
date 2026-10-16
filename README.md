# Phice

Use an iPhone as an air mouse for macOS — point the phone, the cursor follows.

The phone streams orientation and touch over WebRTC and the Mac app drives the
cursor. The phone client is a web page, so there is nothing to install on it.

## Setup

1. Open `Phice.app` and grant Accessibility — that is what moves the cursor.
   The build is unsigned, so the first launch needs Privacy & Security ›
   **Open Anyway**.
2. Switch it on from the menu bar. It mints no pairing code until you do.
3. Open <https://phice.vercel.app/app> on the phone, enter the code, tap Start.

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

## Development

```bash
uv run pytest -q          # tests
uv run ruff check .       # lint
./packaging/build.sh      # dist/Phice.app
```

Drive the whole system with no iPhone, through the same letterbox a real one uses:

```bash
uv run phice --config-dir /tmp/e2e --http-port 18080 run --backend fake --headless &
curl -s "http://127.0.0.1:18080/debug/enable?v=1"   # pairing is off until asked for
uv run python tools/fake_phone.py --pattern sweep --check --http-port 18080
```

Architecture and the non-negotiable constraints: [CLAUDE.md](CLAUDE.md).

## Licence

MIT
