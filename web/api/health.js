// Reports whether storage is wired up and what the deployment can see.
// Names only, never values: this endpoint is public.
import { configured } from "./_redis.js";

export default function handler(req, res) {
  const all = Object.keys(process.env).sort();
  res.status(200).json({
    storage: configured() ? "connected" : "missing",
    // Anything that looks like it came from a database integration.
    candidates: all.filter((k) => /REDIS|KV_|UPSTASH|REST_API|DATABASE|STORAGE/i.test(k)),
    // Everything else, so a wrong prefix is visible rather than invisible.
    env_names: all.filter((k) => !/^(npm_|_$)/.test(k)),
  });
}
