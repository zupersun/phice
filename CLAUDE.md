# Phice

Turn an iPhone into a MacBook-style trackpad. A native Swift iPhone app recognises the gestures
and talks **peer-to-peer** to a tiny Swift agent on the Mac, which applies Apple's own pointer
curves and posts the events. No server between them. Every setting lives on the phone; the Mac
agent is meant to be forgotten.

- Design (approved mockups, including the animated swallow):
  https://claude.ai/artifact/ABsR71QBPUtLGgDbPhjzhn
- Build plan, decisions and phases: `~/.claude/plans/i-want-to-build-shimmering-pudding.md`
- The Python air mouse this replaces is archived on branch `air-mouse` (its last release
  is `v0.2.1`), to be built on later: `git worktree add .worktrees/air-mouse air-mouse` checks it
  out. `web/` stays until the Swift version ships: Vercel deploys the
  hosted page from it.

## Commands

```bash
swift test                                    # PhiceCore + PhiceNet (must stay green)
cd Apps && xcodegen generate                  # regenerate Phice.xcodeproj (gitignored)
xcodebuild -project Apps/Phice.xcodeproj -scheme PhiceMac -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO build               # dev builds unsigned: signing prompts for the keychain
xcodebuild -project Apps/Phice.xcodeproj -scheme PhiceiOS -derivedDataPath .build/xcode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
./scripts/deploy-web.sh                       # the old hosted page, until it is retired
```

After a merge that changes `Sources/`, Xcode can keep building against a stale PhiceKit and
report members that plainly exist as missing ("has no member 'tuning'"): add `clean` before
`build`/`test`. After a merge that adds app files, run `xcodegen generate` again.

On the iPhone (paired as "Jasper's iPhone"; cable once, then Developer Mode, then Wi-Fi works):

```bash
xcodebuild -project Apps/Phice.xcodeproj -scheme PhiceiOS -derivedDataPath .build/xcode \
  -destination 'id=00008150-000C0D6A3EE3401C' -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008150-000C0D6A3EE3401C \
  .build/xcode/Build/Products/Debug-iphoneos/PhiceiOS.app
xcrun devicectl device copy from --device 00008150-000C0D6A3EE3401C --domain-type appDataContainer \
  --domain-identifier com.phice.ios --source Documents/probe.csv --destination /tmp/probe.csv
```

Xcode never needs to be open. The simulator cannot test real multi-touch, contact radius,
haptics or peer-to-peer Wi-Fi; those are verified on the phone, and recorded sessions
(`PhoneToMac.record`) replayed through `swift run phice-replay` make each round reproducible.

## Architecture

```
Sources/PhiceCore/   pure: Foundation only, no I/O, no UIKit/AppKit/Network, time passed in
  Protocol/          Touch, TouchFrame, PadEvent, PhoneToMac, MacToPhone, ClipItem, FrameCodec
  Gestures/          Recogniser: touches -> PadEvents and per-touch verdicts (runs on the phone)
  Pointer/           Apple's acceleration curves, scroll curves, momentum
  Settings/          TrackpadSettings: the Mac's own trackpad settings
  Driver/            MacDriver: PadEvents -> EventPoster calls (runs on the Mac); FakePoster
Sources/PhiceNet/    Network.framework: Bonjour + peer-to-peer, pairing, PSK, framing; Loopback fake
Apps/iOS/            SwiftUI app: pad, glow, pill, menu, clipboard column, settings, onboarding
Apps/Mac/            agent: setup window, login item, CGEvent poster, pasteboard, settings reader
tools/               phice-replay, fake-phone, trackpad-probe (SwiftPM executables)
```

Nothing points backwards: PhiceCore <- PhiceNet <- apps.

- **Gestures are recognised on the phone.** Tap and force timing must not see Wi-Fi jitter, and
  the glow, haptics and the swallow need answers instantly. The phone sends meaning, not touches.
- **The Mac applies the curves and posts.** It owns the user's settings and Apple's curves
  (`HIDAccelCurves`, `HIDScrollAccelCurves` from ioreg), applies them to phone-timestamped deltas,
  and runs scroll momentum locally after `scrollEnded` so momentum never stutters on the network.
- **Inbound data is validated in two places only:** `FrameDecoder` (size, shape) and `MacDriver`
  (clamps every number before it reaches a CGEvent). Downstream code may assume both ran.
- **The contracts are `Sources/PhiceCore/Protocol/*`, `Driver/EventPoster.swift`,
  `Gestures/Recogniser.swift`'s public surface and `Sources/PhiceNet/Link.swift`.** Several
  people build against them at once; change them only as a coordinated change.
- **Touches that begin on the pill never reach the recogniser.** The pill's view owns them
  (hold menu, drag-out to paste).

## Constraints that are not negotiable

Carried over from the Python version, where each was learned the hard way, plus new ones.

1. **Silence releases the mouse.** After `MacDriver.silenceTimeout` (0.5 s) without any message,
   heartbeats included, a held button is released and momentum stops. Without it a phone that
   vanishes mid-drag leaves a mouse button held down forever. The phone heartbeats at 10 Hz.
2. **Posted scroll events are subject to scroll reversers, not to Natural scrolling.** macOS
   applies Natural only to real devices; Scroll Reverser, Mos and LinearMouse negate any event
   that looks like a mouse's, posted ones included. The poster tags each scroll event it posts,
   watches it come out of a listen-only tap behind every reverser, and pre-flips the next ones
   when the sign has flipped. Port it from `src/phice/cursor_backend.py` on `air-mouse`.
   Do not replace it with reading `com.apple.swipescrolldirection`.
3. **Never change `com.phice.app` and never lose the "Phice Self Signed" certificate.** macOS
   keys the Accessibility grant to the designated requirement (identifier + certificate root);
   ad-hoc signing makes it a cdhash that changes every build and silently drops the grant.
   Back it up: `security export -k login.keychain-db -t identities -f pkcs12 -o phice-id.p12`.
   Moving to a Developer ID later costs every user one re-grant, once.
4. **The menu bar may be unreachable.** On a notched Mac with a full menu bar new status items
   land behind the notch and cannot be seen or clicked (measured). The agent has no Dock tile
   and no menu bar item; launching it again opens its window. Never make the menu bar the only
   way in.
5. **One activation policy from launch.** Toggling accessory/regular per window drops window
   orderings two or three times in four. `LSUIElement` stays fixed.
6. **Ask for event-posting access from the agent itself** (`CGRequestPostEventAccess`), never from
   a terminal, or macOS lists the terminal. A new grant takes effect after the agent relaunches.
7. **The Allow click is the pairing security boundary.** The Mac accepts a new phone only for 60 s
   after Pair New iPhone is clicked, closes after one answer, and refuses both when two devices ask
   at once: iOS names every phone "iPhone", so the dialog cannot tell a nearby attacker from the
   user's phone, and the race is all there is to defend (the user chose this over a matching code).
   First contact is a key agreement the user approves on the Mac; every later connection is TLS 1.2
   PSK. The Mac lists paired phones and can remove them. No unauthenticated message ever reaches
   `MacDriver`.
8. **Nothing user-visible on the clipboard leaks.** Items marked `org.nspasteboard.ConcealedType`
   or `TransientType` are never shown, sent to the phone, or written to disk.

## Working in parallel

- Worktrees live in `.worktrees/<branch>` (gitignored). Each piece of work owns its paths and
  commits only to its own branch; the lead merges into `main`.
- `Apps/project.yml` uses whole folders as sources, so adding files never touches the project.
  Change `project.yml` or `Package.swift` only through the lead.
- Other sessions may commit to the main checkout while you work: re-read before editing.

## External services

| Service | Plan | Status |
|---|---|---|
| GitHub | free | the repo |
| Vercel + Redis Cloud | free tiers (Vercel Hobby is non-commercial) | the old hosted page; retire once the Swift version ships |
| Apple Developer Program | $99/yr | needed for TestFlight, the App Store and notarizing the Mac agent; not yet enrolled |

## Conventions

- Follow the user's global CLAUDE.md: no `Co-Authored-By` trailer unless
  `.claude/settings.json` sets `attribution.commit`.
- Swift 6 language mode, strict concurrency. Tests use Swift Testing (`import Testing`).
- Files under 500 lines; line length 104. One state machine may exceed it if every cut through it
  would need callbacks back into itself; say so at the top of the file.
- Write the failing test first, watch it fail, then implement.
- Tests assert behaviour, not implementation.
- Prefer editing existing files; do not add documentation files unless asked.
