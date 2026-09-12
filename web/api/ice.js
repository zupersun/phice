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
const TTL_SECONDS = 6 * 60 * 60;

function stun() {
  return [{ urls: "stun:stun.l.google.com:19302" }];
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
