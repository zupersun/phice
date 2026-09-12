// Letterbox for the phone's WebRTC answer. Same shape as offer.js, shorter TTL:
// by the time an answer exists the Mac is already polling for it.
import { configured, del, getJson, setJson } from "./_redis.js";

const TTL_SECONDS = 120;
const CODE_RE = /^[A-Z2-9]{6}$/;

export default async function handler(req, res) {
  if (req.method === "OPTIONS") return res.status(204).end();
  if (!configured()) {
    return res.status(503).json({ error: "no storage connected to this deployment" });
  }

  if (req.method === "POST") {
    const { code, sdp, type } = req.body || {};
    if (!CODE_RE.test(code || "")) return res.status(400).json({ error: "bad code" });
    if (type !== "answer" || typeof sdp !== "string" || sdp.length > 64_000) {
      return res.status(400).json({ error: "bad answer" });
    }
    await setJson(`answer:${code}`, { sdp, type }, TTL_SECONDS);
    return res.status(200).json({ ok: true });
  }

  if (req.method === "GET") {
    const code = String(req.query.code || "");
    if (!CODE_RE.test(code)) return res.status(400).json({ error: "bad code" });
    const hit = await getJson(`answer:${code}`);
    if (!hit) return res.status(404).json({ error: "not found" });
    // Single use: consuming it stops a replay taking over the session.
    await del(`answer:${code}`);
    return res.status(200).json(hit);
  }

  return res.status(405).json({ error: "method not allowed" });
}
