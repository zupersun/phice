// Letterbox for the phone's WebRTC answer. Same shape as offer.js, shorter TTL:
// by the time an answer exists the Mac is already polling for it.
import { kv } from "@vercel/kv";

const TTL_SECONDS = 120;
const CODE_RE = /^[A-Z2-9]{6}$/;

export default async function handler(req, res) {
  if (req.method === "OPTIONS") return res.status(204).end();

  if (req.method === "POST") {
    const { code, sdp, type } = req.body || {};
    if (!CODE_RE.test(code || "")) return res.status(400).json({ error: "bad code" });
    if (type !== "answer" || typeof sdp !== "string" || sdp.length > 64_000) {
      return res.status(400).json({ error: "bad answer" });
    }
    await kv.set(`answer:${code}`, { sdp, type }, { ex: TTL_SECONDS });
    return res.status(200).json({ ok: true });
  }

  if (req.method === "GET") {
    const code = String(req.query.code || "");
    if (!CODE_RE.test(code)) return res.status(400).json({ error: "bad code" });
    const hit = await kv.get(`answer:${code}`);
    if (!hit) return res.status(404).json({ error: "not found" });
    // Single use: consuming the answer prevents a replay taking over the session.
    await kv.del(`answer:${code}`);
    return res.status(200).json(hit);
  }

  return res.status(405).json({ error: "method not allowed" });
}
