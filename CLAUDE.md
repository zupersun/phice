# Phice

Use an iPhone as a Wii-remote-style air mouse for macOS. A background Mac app serves a web
page to the phone over TLS; the phone streams orientation and touch at 60 Hz over a
WebSocket; the Mac decides everything and drives the cursor.

**There is no iOS app and there must not be one.** The phone client is a plain web page —
no framework, no build step, no Apple Developer account.

## Commands

```bash
uv run pytest -q          # full suite (must stay green)
uv run ruff check .       # lint (must stay clean)
uv run phice install      # (re)install + restart the login agent
uv run phice uninstall    # remove it
uv run phice paths        # where config lives
uv run phice tailscale    # switch to a trusted tailnet certificate
uv run phice setup-url    # print setup URLs
uv run phice grant        # ask macOS for Accessibility (from the agent, not the shell)
```

Exercise the whole system without a phone, via real TLS against a real server:

```bash
uv run phice --config-dir /tmp/e2e --tls-port 18443 --http-port 18080 \
  run --backend fake --headless &
uv run python tools/fake_phone.py --pattern sweep --check \
  --config-dir /tmp/e2e --tls-port 18443 --http-port 18080
```

Patterns: `still roll sweep square click doubleclick rightclick drag chord scroll rest`.
All eleven must pass before shipping. Drop `--backend fake` to drive the real cursor.

`tools/replay.py <session.jsonl> --compare gain_x_px_per_deg=60` replays a recording
offline and prints path statistics — the tuning loop, and a language-independent
golden-master suite if the engine is ever ported.

## Diagnosing "it doesn't work"

Check this first. It answers, in one look, which layer is broken:

```bash
curl -s http://127.0.0.1:8080/debug/cursor | python3 -m json.tool
```

```json
{"connected": true, "phase": "on", "accessibility": false, ...}
```

| Reading | Meaning |
|---|---|
| `connected: false` | The phone never reached the server. Network or certificate. |
| `connected: true, phase: "off"` | Connected, pointer not armed. Tap POWER. |
| `phase: "on", accessibility: false` | Everything works except the macOS permission. |
| `phase: "on", accessibility: true`, cursor frozen | A real engine bug. Now it is worth reading code. |

`phice grant` asks macOS for Accessibility **from the running agent**, which is what
makes it list the right binary. Prompting from a terminal would add the terminal
instead. A granted permission only takes effect after the agent restarts
(`phice install`).

A blank page on the phone has three unrelated causes that look identical: an
untrusted certificate, a WebSocket origin 403, and the phone being unable to route
to the Mac at all. Do not guess between them — `http://<mac>:8080/check` loads over
plain HTTP and probes the TLS port, which separates the first from the others.

## macOS integration

Two rough edges, both caused by the same thing: the app has no macOS identity. It
runs as a bare `python3.13` out of a uv-managed venv, not an app bundle.

- **`accessibility` gates nothing** — it is only reported to the phone, so the cursor can
  move while the status says otherwise. The runtime polls it in `_status_loop`; do not
  move that back to the menu bar, which may never appear.
- **Accessibility** must be granted to the real interpreter,
  `~/.local/share/uv/python/cpython-*/bin/python3.13`, not to `phice`. It is in a
  hidden directory, so `open` that folder in Finder and drag the binary into
  System Settings rather than fighting the file picker. Re-adding an entry that is
  already listed does nothing; remove it with **−** first.
  Running the binary from a terminal reports `AXIsProcessTrusted() == True` because
  it inherits the terminal's grant — that tells you nothing about the launch agent.
- **The menu bar icon may be invisible.** macOS adds new status items to the left of
  existing ones; on a notched Mac with a full menu bar they land behind the notch.
  Never rely on the menu bar as the only way to see state — that is why the debug
  hook above reports the full status.

A minimal `Phice.app` bundle would fix both: a real name and icon in the
Accessibility list, and a proper status item. Not built yet.

## Architecture

Dependency order, and nothing may point backwards:

```
orientation  filters  protocol  paths     (no dependencies)
config       <- paths
engine       <- config cursor_backend filters orientation protocol
server       <- engine pairing certs config paths
runtime      <- server setup_server
menubar cli  <- runtime
```

- `engine.py` is **pure**: a clock and a cursor backend are injected, so every behaviour is
  unit-testable with no sleeping, no real time and no real cursor. Keep it that way — no I/O.
- `protocol.py` is the **only** place inbound data is validated. Downstream code may assume
  a `SensorPacket` is sane.
- All visual design lives in `defaults/theme.css` and `defaults/layout.json`. `web/app.js`
  sets no colour, size, font or label — it renders whatever `layout.json` describes. Never
  hardcode appearance in JS.

  When the page needs to drive an animation, it publishes a **number** as a CSS custom
  property and lets the theme decide what that means. The scroll strip is the pattern to
  copy: `app.js` sets `--scroll-pos` (0..1, where the finger is along the strip) and
  `theme.css` turns it into the thumb's position, size, colour and easing. Adding a
  `transform` or a colour to the JS would break the contract.

Editing `defaults/` does **not** change a running install: `Paths.ensure()` deliberately
never overwrites user-edited files. Copy to `~/Library/Application Support/Phice/` as well,
or tell the user to run `phice reset-ui`.

## Constraints that are not negotiable

These were each discovered the hard way. Changing them re-breaks the product.

1. **A periodic engine tick is mandatory.** Pending clicks, the recenter hold and the packet
   timeout are all time-based. Without it a phone that stops sending mid-press leaves a
   mouse button held down forever.
2. **Motion references must update while the cursor is frozen.** Both `_prev_f` (relative)
   and `_anchor` (absolute) update *before* the frozen check. Skip it and releasing a clutch
   snaps the cursor by however far you turned while holding it.
3. **A button absent from a packet is skipped, not released.** The page sends every layout
   button every packet, so absence means "does not exist yet", typically right after a
   layout change. Treating it as a release fires phantom events.
4. **Adopt button counters silently on first sighting.** After a reconnect the page's
   counters keep climbing; diffing against zero replays every press ever registered.
5. **Pairing tokens live in a file, not memory.** `phice pair-token` runs in a different
   process from the menu bar app.
6. **Never record the raw `hello` frame.** It carries a pairing token. The recorder writes a
   scrubbed session marker, which `replay.py` also needs to reset the engine between sessions.
7. **The leaf certificate needs an Authority Key Identifier.** OpenSSL 3.x strict
   verification rejects the chain without it (RFC 5280).
8. **The WebSocket origin allow-list must cover every name in the certificate** — IPs and
   the tailnet FQDN, not just `<host>.local`. A rejected origin 403s the socket, which the
   phone renders as a blank page: identical symptom to an untrusted certificate, unrelated
   cause.
9. **Do not call the Tailscale GUI's CLI from the runtime.** From the launch agent it exits
   0 but prints plain text instead of JSON. The name is resolved once by `phice tailscale`
   and stored as `tailscale_host` in config.
10. **Never dispatch to the asyncio loop unguarded.** The menu bar outlives the runtime
    thread; use `Runtime._dispatch`, which discards the coroutine if the loop is closed.
11. **Do not block the asyncio thread in tests.** `asyncio.to_thread` blocking HTTP calls or
    the server cannot answer and the test times out.
12. **iOS will not install a bare `.crt`.** Serve `/ca.mobileconfig` as
    `application/x-apple-aspen-config`.

## Why TLS is not optional

Safari exposes motion sensors only on a secure page, and a secure page cannot open an
insecure WebSocket. Hence HTTPS, hence a certificate. `cert_mode`:

- `tailscale` — a real Let's Encrypt certificate for the MagicDNS name. Nothing to install
  on the phone and it works across networks, including cellular. **Preferred.**
- `auto` — self-signed local CA; the phone must install and trust a profile, and both
  devices must be on the same network with mDNS or direct IP reachable.
- `external` — the user supplies `certs/server.{crt,key}`.

Network reality: university and corporate Wi-Fi usually block mDNS and isolate clients, so
`.local` and direct IP both fail there. A phone on cellular cannot reach a `10.x` address
at all. Only `tailscale` covers every case.

## Conventions

- Worktrees for plan execution live in `.worktrees/<branch>` (gitignored).

- Follow the user's global CLAUDE.md: no `Co-Authored-By` trailer unless
  `.claude/settings.json` sets `attribution.commit`.
- Files under 500 lines; line length 104.
- Write the failing test first, watch it fail, then implement.
- Prefer editing existing files; do not add documentation files unless asked.
- Tests assert behaviour, not implementation. When a test fails after a deliberate
  behaviour change, decide whether the test encodes the old contract and pin it explicitly
  (see `mapping="relative"` in `test_edge_clamp_and_edge_drag`) rather than loosening it.
