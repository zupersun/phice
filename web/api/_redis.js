// Minimal Redis client over Upstash's REST API.
//
// Vercel's own KV product is gone; storage is now the Marketplace, where Upstash
// provides Redis. Talking to its REST endpoint with fetch avoids an SDK, an
// install step, and a dependency that gets renamed again in a year. The env var
// names differ depending on how the integration was connected, so accept either.
const BASE = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;

export function configured() {
  return Boolean(BASE && TOKEN);
}

async function command(args) {
  const res = await fetch(BASE, {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`redis ${res.status}`);
  const body = await res.json();
  if (body.error) throw new Error(body.error);
  return body.result;
}

/** Store a JSON value under `key`, expiring after `seconds`. */
export async function setJson(key, value, seconds) {
  await command(["SET", key, JSON.stringify(value), "EX", String(seconds)]);
}

/** Read a JSON value, or null if it is absent or unreadable. */
export async function getJson(key) {
  const raw = await command(["GET", key]);
  if (raw == null) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export async function del(key) {
  await command(["DEL", key]);
}
