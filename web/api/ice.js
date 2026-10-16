// Mints short-lived TURN credentials for both peers.
//
// A relay is required whenever the two devices are on different networks behind
// NAT, which is most of the time: a phone on carrier NAT and a Mac on a campus
// network can each reach outward and neither can be reached. Handing both sides
// the SAME list from one place is what makes them pair -- mismatched ICE
// configuration gathers candidates that cannot meet.
//
// Credentials are generated per request and expire, so nothing long-lived is
// stored in the page, the app, or this repository.
import { bump, configured } from "./_redis.js";

const TTL_SECONDS = 6 * 60 * 60;

// Minting is unauthenticated, because the Mac needs a relay before it has a
// pairing code and the page before it has anything at all. Unthrottled, that
// makes this a free relay for anyone who finds the URL, drawn against the one
// quota in the project that can actually bill. A pairing costs two calls and the
// Mac then caches for half the TTL, so a real user never approaches this.
const WINDOW_S = 60 * 60;
const MAX_PER_WINDOW = 30;

function stun() {
  return [{ urls: "stun:stun.l.google.com:19302" }];
}

function clientIp(req) {
  // x-real-ip is set by the platform. The LEFTMOST x-forwarded-for entry is
  // whatever the caller sent and so is worthless for throttling -- take the
  // rightmost, which is the hop the edge itself added.
  const real = req.headers["x-real-ip"];
  if (typeof real === "string" && real.trim()) return real.trim();
  const fwd = req.headers["x-forwarded-for"];
  const chain = (Array.isArray(fwd) ? fwd.join(",") : fwd || "").split(",").map((p) => p.trim());
  return chain.filter(Boolean).pop() || req.socket?.remoteAddress || "unknown";
}

/** True if this caller has had its share this hour. Redis down means let them through:
 *  a letterbox outage must not stop pairing, and the spend cap is the real backstop. */
async function overLimit(req) {
  if (!configured()) return false;
  try {
    return (await bump(`ice:${clientIp(req)}`, WINDOW_S)) > MAX_PER_WINDOW;
  } catch {
    return false;
  }
}

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  const keyId = process.env.TURN_KEY_ID;
  const token = process.env.TURN_API_TOKEN;

  // Without a relay configured the service still answers, with STUN only. That
  // works on a shared network and fails across networks -- which is the truth,
  // and better than an error the caller cannot act on.
  if (!keyId || !token) {
    return res.status(200).json({ iceServers: stun(), relay: false, reason: "no TURN configured" });
  }

  // Only worth a Redis round-trip once there is a key to protect.
  if (await overLimit(req)) {
    // Same honest degradation as a missing key: STUN still pairs on one network.
    return res.status(200).json({ iceServers: stun(), relay: false, reason: "rate limited" });
  }

  const url = `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`;
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ ttl: TTL_SECONDS }),
    });
    if (!r.ok) {
      const text = (await r.text().catch(() => "")).slice(0, 200);
      return res.status(200).json({
        iceServers: stun(), relay: false, reason: `cloudflare HTTP ${r.status}: ${text}`,
      });
    }
    const body = await r.json();
    // Cloudflare returns either a single object or an array, depending on version.
    const raw = body.iceServers;
    const servers = Array.isArray(raw) ? raw : raw ? [raw] : [];
    if (!servers.length) {
      return res.status(200).json({ iceServers: stun(), relay: false, reason: "empty response" });
    }
    return res.status(200).json({ iceServers: servers, relay: true, ttl: TTL_SECONDS });
  } catch (e) {
    return res.status(200).json({
      iceServers: stun(), relay: false, reason: String(e.message || e).slice(0, 200),
    });
  }
}
