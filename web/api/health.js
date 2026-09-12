// Reports whether storage is wired up AND whether it actually answers.
// Never exposes the token; the host is reduced to its shape.
import { configured, hostShape, ping } from "./_redis.js";

export default async function handler(req, res) {
  const candidates = Object.keys(process.env)
    .filter((k) => /REDIS|KV_|UPSTASH|REST_API|DATABASE|STORAGE/i.test(k))
    .sort();
  const result = configured() ? await ping() : { ok: false, error: "no credentials found" };
  res.status(200).json({
    storage: configured() ? "credentials found" : "missing",
    reachable: result.ok,
    detail: result.ok ? result.reply : result.error,
    host: hostShape(),
    candidates,
  });
}
