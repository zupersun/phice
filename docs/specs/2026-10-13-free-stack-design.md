# A Phice that costs nothing to run, for anyone

**Status:** design, awaiting one experiment before any code.
**Decision taken:** same-network-only is the supported configuration. Pairing across
networks is dropped.

## What this is for

Today Phice depends on three accounts that are Jasper's: a Vercel project, a Redis
instance and a Cloudflare TURN key. They are free at his scale and not free at every
scale, the Vercel hobby tier forbids commercial use, and a user who clones the repo
cannot run it without provisioning their own. The goal is a Phice that any user runs
with what they already own, where nothing meters, nothing expires, and no card exists.

## The one constraint everything bends around

Safari exposes motion sensors only in a **secure context**. That single rule caused every
architectural decision in this project, including the hosted page. A page served from the
Mac over plain HTTP on the LAN is not a secure context, so the phone could not read its
own gyroscope, and there is no product.

Everything else is negotiable. This is not.

## What same-network-only buys immediately

Accepting the constraint deletes two of the three services outright:

- **Cloudflare TURN goes.** A relay exists only for peers that cannot reach each other.
  On one Wi-Fi they connect on host candidates directly. This is the only metered
  dependency in the project, so metering disappears with it.
- **Redis goes.** It exists to hold an offer for a few seconds between two devices that
  could not otherwise find each other. Two devices in the same room have better ways.

What remains is the page itself, and the 66 bytes of signalling.

## Measured, not assumed

A real offer from `aiortc` with no STUN and no TURN:

| Payload | Bytes |
|---|---|
| SDP as generated | 1012 |
| SDP deflated | 630 |
| Hand-packed binary | **66** |

Everything else in an SDP is boilerplate both ends already know: it is always a
data-channel-only BUNDLE offer with `sctp-port 5000`. The irreducible content is a
SHA-256 fingerprint (32 bytes), ICE ufrag and password (26), one IPv4 address and port
(6), and a role byte.

66 bytes is **a QR version 5 symbol, 45x45 modules** in base32, which reads off a screen
at arm's length. It was verified end to end on 2026-10-13: an offer was packed to 66
bytes, expanded from the template on the far side, and a data channel opened and carried
a message **in both directions on reconstructed SDP**. The signalling server exists to
move 66 bytes, and it does not need to.

macOS decodes QR natively through `CIDetector`, which arrives with the `Quartz`
dependency the project already has. A 106-character payload round-tripped correctly.

## Two routes, and the experiment that chooses between them

### Route A — static page, out-of-band handshake

The page becomes a static file on any static host. No functions, no database, no
per-request metering, nothing that can be throttled or billed. It is fetched once and a
service worker serves it offline afterwards, so a returning user touches the network
never.

Pairing without a server:

1. The Mac shows a QR of `https://<host>/app#o=<base32 offer>`. A URL fragment is never
   sent to the server, so the offer stays between the two devices.
2. The user points the **iOS Camera app** at it. Safari opens with the offer already in
   hand. No in-page scanner, no camera permission, no QR library to vendor.
3. The phone builds its answer and shows it as a QR, or copies it to the clipboard.
4. The Mac takes the answer back by **Universal Clipboard** (it watches its own pasteboard
   for a `PHICE1:` prefix, needing no permission and no new dependency) or by **webcam**
   where Handoff is unavailable.

Honest cost: the return leg is the awkward part. Clipboard is seamless when both devices
share an Apple ID and invisible when they do not; the webcam means holding a phone up to
a laptop camera.

### Route B — the Mac serves the page itself

If the Mac serves the page over HTTPS, there is **no external dependency at all** and no
handshake problem: the page's origin is the Mac, so it can fetch `/api/offer` from the Mac
directly. No QR, no clipboard, no camera, no static host. Pairing stays exactly as it is
today, minus the letterbox.

This project already tried a version of this and removed it on 2026-09-22. The recorded
reasons were a configuration profile that took six steps on the phone, networks with
client isolation, and phones on cellular. **Two of those three are now out of scope**, and
the third was a property of installing a CA profile, not of serving HTTPS. The untried
path is the ordinary one: navigate to the Mac directly, accept the certificate warning
once, and let Safari remember it.

### The experiment

Route B is better if and only if iOS Safari treats a page with a user-accepted
self-signed certificate as a secure context for `DeviceMotionEvent.requestPermission()`.
I could not determine this from the code or from first principles, and it needs a real
iPhone:

1. Serve the existing page from the Mac over HTTPS with a self-signed certificate on a
   LAN address.
2. On the phone, open it, tap through the warning.
3. Tap Start and observe whether motion permission is granted and events arrive.

If events arrive, build Route B and the external dependency count goes to zero.
If Safari refuses, build Route A, which is proven today.

## What we give up, stated plainly

Networks with client isolation, common on university and corporate Wi-Fi, will not pair
at all. Today's relay covers that case. This is the cost of the decision already taken,
and it should be surfaced honestly in the UI rather than presented as a failure: the Mac
can detect that no candidate pair succeeded and say so.

The relay can remain as an opt-in for anyone who needs it, configured with their own
credentials. The default path costs nothing.

## Order of work

1. Run the experiment above. It decides the architecture and takes minutes.
2. Make the engine LAN-only: no ICE servers, host candidates only. Small and independent
   of the outcome.
3. Build the chosen route behind the existing config, so the hosted path keeps working
   until the replacement is proven on real devices.
4. Retire the Vercel project, the Redis instance and the TURN key, in that order, only
   once a real phone has paired without them.
