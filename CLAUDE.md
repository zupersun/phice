# Phice

Use an iPhone as a Wii-remote-style air mouse for macOS. A hosted web page pairs the phone
with a background Mac app by a six-character code; the phone streams orientation and touch
at 60 Hz over a WebRTC data channel; the Mac decides everything and drives the cursor.

**There is no iOS app and there must not be one.** The phone client is a plain web page —
no framework, no build step, no Apple Developer account.

## Commands

```bash
uv run pytest -q          # full suite (must stay green)
uv run ruff check .       # lint (must stay clean)
uv run phice install      # (re)install + restart the login agent
uv run phice uninstall    # remove it
uv run phice paths        # where config lives
uv run phice grant        # ask macOS for Accessibility (from the agent, not the shell)
./scripts/deploy-web.sh   # deploy web/ and prove the live app.js matches the repo
```

Exercise the whole system without a phone. The fake phone reads the code off the Mac's
debug hook and pairs through the same letterbox a real phone uses, so the hosted service
must be reachable:

```bash
uv run phice --config-dir /tmp/e2e --http-port 18080 run --backend fake --headless &
uv run python tools/fake_phone.py --pattern sweep --check --http-port 18080
```

Patterns: `still roll sweep square click doubleclick rightclick drag chord scroll rest`.
All eleven must pass before shipping. Drop `--backend fake` to drive the real cursor.
`tests/test_rtc.py` exercises the same transport with two in-process peers and no network.

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
| `connected: false` | No session. Either the code was never entered, or the offer and answer never met: an expired code, or two networks with no relay between them (`/api/ice` on the letterbox reports `relay: false` and why). |
| `connected: true, phase: "off"` | Connected, pointer not armed. Press any button. |
| `phase: "on", accessibility: false` | Everything works except the macOS permission. |
| `phase: "on", accessibility: true`, cursor frozen | A real engine bug. Now it is worth reading code. |
| `rtc.frames` climbing, `sensor_hz: 0` | Buttons arrive, motion does not. The phone was refused sensor access; it reports what iOS answered in `phone connected: ... (caps: ...)`. |
| `rtc.bad` climbing | The page and `protocol.py` disagree. `rtc.last_error` names the field. |

The pointer switching itself off a second after it is armed is the packet timeout doing
its job, not a bug: no packets are arriving.

`phice grant` asks macOS for Accessibility **from the running agent**, which is what
makes it list the right binary. Prompting from a terminal would add the terminal
instead. A granted permission only takes effect after the agent restarts
(`phice install`).

A phone stuck on "Connecting…" and a phone showing an unstyled pad are different
failures. The first means the data channel never opened (see `connected` above).
The second means it opened and the theme did not arrive whole; the Mac's log has
the phone's own report of what it received, sent back over the control channel.

## macOS integration

The shipped artefact is `dist/Phice.app`, built by `./packaging/build.sh`.

- **Packaged resources come from `paths.resource_dir()`**, which returns `sys._MEIPASS`
  when frozen. `__file__` does not work inside a bundle. `build.sh` proves this by
  running the built binary against a temp config dir rather than checking that files
  exist at a guessed path — PyInstaller's macOS layout has moved between versions, and
  a path check passed a bundle that was missing `defaults/assets/` and crashed on first
  launch.
- **The Accessibility grant keys on the designated requirement, not the bundle id alone.**
  Signed with the self-signed identity it is
  `identifier "com.phice.app" and certificate root H"..."` — stable across rebuilds,
  verified by building twice and diffing. Ad-hoc signed it is a bare cdhash that changes
  every build, so each rebuild silently drops the permission while the stale entry still
  shows Phice switched on. Never change `CFBundleIdentifier`, and **never lose the
  certificate**: `./packaging/create-signing-identity.sh` creates it, and once shipped
  every user's grant is bound to it. Back it up with
  `security export -k login.keychain-db -t identities -f pkcs12 -o phice-id.p12`.
- **This is not a Developer ID.** Downloaded copies still hit Gatekeeper
  ("unidentified developer"); on macOS 15+ users must use System Settings ›
  Privacy & Security › **Open Anyway**, since right-click → Open no longer works. Only
  a paid Developer ID plus notarization removes that. Signing fixes updates, not first
  launch.
- **The launch agent runs the bundle executable directly when frozen.** `-m phice` would
  be passed to the app as an argument, not understood as a module. `--config-dir` is a
  top-level argparse option and must precede `run`; `tests/test_cli_agent.py` feeds the
  generated argv through the real parser, because asserting its *shape* let a
  regression through that exits with `SystemExit(2)` and no menu bar icon.
- **`accessibility` gates nothing** — it is only reported to the phone, so the cursor can
  move while the status says otherwise. The runtime polls it in `_status_loop`; do not
  move that back to the menu bar, which may never appear.
- **The control panel is a WKWebView, not native widgets**, so its design lives in
  `panel.css` in the config folder and the user can restyle it exactly like the phone's
  theme. It loads `http://127.0.0.1:<port>/panel`, which App Transport Security blocks
  unless the bundle declares `NSAllowsLocalNetworking` -- the only symptom is a blank
  window. It opens at every launch because the pairing code changes each launch.
- **The menu bar icon may be invisible.** macOS adds new status items to the left of
  existing ones; on a notched Mac with a full menu bar they land behind the notch.
  Never rely on the menu bar as the only way to see state — that is why the debug hook
  reports the full status.
- **The bundle is arm64-only.** uv's CPython builds are per-arch, so `universal2` is not
  available; `build.sh` prints the architecture it produced.

## Architecture

Dependency order, and nothing may point backwards:

```
orientation  filters  protocol  paths  templates  calibrate   (no dependencies)
config       <- paths
engine       <- config cursor_backend filters orientation protocol
rtc          <- engine paths protocol
signaling    <- rtc
control      <- templates
runtime      <- calibrate config control engine paths rtc signaling
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
5. **Record a session marker for `hello`, not the raw frame**, and only once per
   connection. `replay.py` resets the engine on each marker; the page says hello again
   whenever its capabilities change, and a marker there would reset a replay mid-stream.
6. **Never dispatch to the asyncio loop unguarded.** The menu bar outlives the runtime
   thread; use `Runtime._dispatch`, which discards the coroutine if the loop is closed.
7. **Do not block the asyncio thread in tests.** `asyncio.to_thread` blocking HTTP calls or
   the server cannot answer and the test times out.
8. **The page's own chrome must not live in the stylesheet the Mac replaces.**
   `web/app/index.html` has two: `#theme`, overwritten wholesale by the pushed theme, and
   `#shell`, which the page owns. They were one, so the first theme push deleted the rule
   that displays the Start button -- motion access could then never be granted and the
   phone streamed nothing, while the pad rendered perfectly.
9. **The transport must push engine state back.** The phone draws its LED, its recenter
   bar and every reaction from `state` messages. `RTCTransport` wires `engine.on_change`
   the moment the control channel opens; it once shipped without that, and each button
   worked and looked dead.
10. **A fresh session takes the validated layout from the runtime, not `layout.json`.**
    `RTCTransport` is built per session; reading the file gave a phone that reconnected
    after switching to one-handed the two-handed layout back.
11. **`RTCTransport.close()` must be safe to interrupt.** aiortc's `close()` creates its
    internal "closed" future first and resolves it last, so a cancellation landing
    mid-close leaves that future pending forever and every later `close()` on the same
    peer connection deadlocks. `asyncio.shield` keeps the cleanup running while the
    cancellation still reaches the caller. Symptom: the test suite hangs at random, in
    whichever test happens to cancel the signaling loop at the wrong moment.
12. **The scroll strip is a rate control, not a displacement one.** Speed comes from the
    finger's distance from the centre, so holding still off-centre keeps scrolling. Running
    displacement scrolling alongside it doubles the input and feels choppy, which is why
    `scroll_gain` ships at 0.
13. **`requestPermission()` resolves to "denied" without throwing**, and both prompts must
    be *started* inside the user gesture -- awaiting the first puts the second outside it.
    Check the returned value, and then check that events actually arrive: a listener that
    is attached but never fires is indistinguishable from a working one.
14. **The control server binds 127.0.0.1 and nothing else.** Nothing on it is for the
    phone. It once listened on every interface because the phone had to fetch a
    certificate from it; that reason is gone.

## Why the page is hosted

Safari exposes motion sensors only on a secure page, and a secure page cannot open an
insecure connection back to a Mac on the LAN. Serving the page from the Mac therefore
meant a certificate the phone trusted: a self-signed CA installed as a profile, or one
issued for a Tailscale name. Both shipped and both were removed on 2026-09-22. The profile
took six steps on the phone and a network that allowed client-to-client traffic, which
university and corporate Wi-Fi usually do not; the tailnet needed an account on both
devices. Neither reached a phone on cellular from a Mac behind a campus firewall.

The hosted page needs none of that. WebRTC authenticates the peers by DTLS fingerprint, so
the only secret is the six-character code, and the relay covers the case where neither
device can be reached from outside. The cost is that pairing depends on the letterbox
being up; the pointer itself does not, once the channel is open. Do not add a second way
in: the two clients drifted last time, and every phone bug had to be fixed twice.

## External services and what they cost

Everything Phice depends on beyond the Mac itself, what it costs, and how to get
out of it. Check this before assuming a service is free or disposable.

| Service | Plan | What breaks without it |
|---|---|---|
| **GitHub** | free | nothing at runtime |
| **Vercel** | Hobby tier is free but **non-commercial** | the phone page and pairing |
| **Redis Cloud** (via Vercel marketplace) | free tier | pairing; the pointer keeps working once connected |
| **Cloudflare Realtime TURN** | free tier, **1000 GB/month** | pairing across different networks |
| Apple Developer | **not used** | — downloads show "unidentified developer" |

### The TURN relay is the only metered dependency

A relay is required whenever the phone and the Mac are on different networks
behind NAT — a phone on cellular and a Mac on a campus network can each reach
outward and neither can be reached. Measured on a real pair: every non-relayed
candidate failed. On a shared Wi-Fi it connects directly and uses no relay at all.

**Measured cost**, from the real protocol: a 245-byte packet, ~305 bytes on the
wire, 60 Hz, charged in both directions:

- ~132 MB per hour of active pointing
- ~7,600 hours inside the 1000 GB free tier
- Nothing accrues while the pointer is off

Set a **$0 spend cap** in Cloudflare billing so exceeding the tier stops the
service rather than generating a charge. Account and billing specifics are
deliberately not recorded here: this file is public.

### To cancel it

1. Cloudflare dashboard → **Realtime → TURN Server** → delete the key.
2. Vercel → project → **Environment Variables** → remove `TURN_KEY_ID` and
   `TURN_API_TOKEN`, then redeploy.

`/api/ice` degrades honestly rather than breaking: it keeps answering with STUN
only, reports `relay: false` with a reason, and the Mac logs that it will connect
on a shared network and nowhere else. Pairing across networks stops working;
everything else is unaffected.

## Conventions

- Worktrees for plan execution live in `.worktrees/<branch>` (gitignored).

- Follow the user's global CLAUDE.md: no `Co-Authored-By` trailer unless
  `.claude/settings.json` sets `attribution.commit`.
- Files under 500 lines; line length 104. `engine.py` is the deliberate exception at
  ~560: it is one state machine, and every cut through it (buttons from phases, motion
  from freezing) needs so many callbacks back into the engine that the result is longer
  and harder to follow than the file it replaced. Splitting the most load-bearing code
  in the project to satisfy a line count is a bad trade. Everything else obeys the rule.
- Write the failing test first, watch it fail, then implement.
- Prefer editing existing files; do not add documentation files unless asked.
- Tests assert behaviour, not implementation. When a test fails after a deliberate
  behaviour change, decide whether the test encodes the old contract and pin it explicitly
  (see `mapping="relative"` in `test_edge_clamp_and_edge_drag`) rather than loosening it.
