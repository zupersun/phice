// Reports whether storage is wired up, and under which variable names, without
// revealing the values. Diagnosing this blind wasted time once already.
import { configured } from "./_redis.js";

export default function handler(req, res) {
  const names = Object.keys(process.env)
    .filter((k) => /REST_API_(URL|TOKEN)$/.test(k) || /^UPSTASH_/.test(k))
    .sort();
  res.status(200).json({ storage: configured() ? "connected" : "missing", env: names });
}
