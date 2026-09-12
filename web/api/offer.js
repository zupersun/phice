// Letterbox for the Mac's WebRTC offer, addressed by a short pairing code.
// Entries expire: a pairing code is single use and short-lived, and leaving them
// behind would leak connection metadata and fill the free tier.
import { configured, getJson, setJson } from "./_redis.js";

const TTL_SECONDS = 300;
const CODE_RE = /^[A-Z2-9]{6}$/;

export default async function handler(req, res) {
  if (req.method === "OPTIONS") return res.status(204).end();
  if (!configured()) {
    // Say which piece is missing rather than returning an opaque 500.
    return res.status(503).json({ error: "no storage connected to this deployment" });
  }

  if (req.method === "POST") {
    const { code, sdp, type } = req.body || {};
    if (!CODE_RE.test(code || "")) return res.status(400).json({ error: "bad code" });
    if (type !== "offer" || typeof sdp !== "string" || sdp.length > 64_000) {
      return res.status(400).json({ error: "bad offer" });
    }
    await setJson(`offer:${code}`, { sdp, type }, TTL_SECONDS);
    return res.status(200).json({ ok: true, expires_in: TTL_SECONDS });
  }

  if (req.method === "GET") {
    const code = String(req.query.code || "");
    if (!CODE_RE.test(code)) return res.status(400).json({ error: "bad code" });
    const hit = await getJson(`offer:${code}`);
    if (!hit) return res.status(404).json({ error: "not found" });
    return res.status(200).json(hit);
  }

  return res.status(405).json({ error: "method not allowed" });
}
