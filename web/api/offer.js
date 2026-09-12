// Letterbox for the Mac's WebRTC offer, addressed by a short pairing code.
// Entries expire: a pairing code is single use and short-lived, and leaving
// them behind would leak connection metadata and fill the free tier.
import { kv } from "@vercel/kv";

const TTL_SECONDS = 300;
const CODE_RE = /^[A-Z2-9]{6}$/;

export default async function handler(req, res) {
  if (req.method === "OPTIONS") return res.status(204).end();

  if (req.method === "POST") {
    const { code, sdp, type } = req.body || {};
    if (!CODE_RE.test(code || "")) return res.status(400).json({ error: "bad code" });
    if (type !== "offer" || typeof sdp !== "string" || sdp.length > 64_000) {
      return res.status(400).json({ error: "bad offer" });
    }
    await kv.set(`offer:${code}`, { sdp, type }, { ex: TTL_SECONDS });
    return res.status(200).json({ ok: true, expires_in: TTL_SECONDS });
  }

  if (req.method === "GET") {
    const code = String(req.query.code || "");
    if (!CODE_RE.test(code)) return res.status(400).json({ error: "bad code" });
    const hit = await kv.get(`offer:${code}`);
    if (!hit) return res.status(404).json({ error: "not found" });
    return res.status(200).json(hit);
  }

  return res.status(405).json({ error: "method not allowed" });
}
