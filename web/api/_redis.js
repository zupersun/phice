// Minimal Redis client over Upstash's REST API.
//
// Vercel's own KV product is gone; storage is now the Marketplace, where Upstash
// provides Redis. Talking to its REST endpoint with fetch avoids an SDK, an
// install step, and a dependency that gets renamed again in a year. The env var
// names differ depending on how the integration was connected, so accept either.
// The integration lets you choose a prefix, so the names are not fixed. Rather
// than guess, find the pair by shape: a *_REST_API_URL and its matching token.
function discover() {
  const env = process.env;
  for (const key of Object.keys(env)) {
    if (!key.endsWith("_REST_API_URL") || !env[key]) continue;
    const token = env[key.replace(/_URL$/, "_TOKEN")];
    if (token) return { base: env[key], token };
  }
  // Upstash's own naming, if the integration used it verbatim.
  if (env.UPSTASH_REDIS_REST_URL && env.UPSTASH_REDIS_REST_TOKEN) {
    return { base: env.UPSTASH_REDIS_REST_URL, token: env.UPSTASH_REDIS_REST_TOKEN };
  }
  // The Vercel marketplace integration injects only a redis:// connection string.
  // A serverless function cannot readily hold a raw Redis socket, but Upstash
  // serves REST on the same host with the URL's password as the bearer token.
  for (const key of ["KV_REDIS_URL", "REDIS_URL", "KV_URL", "DATABASE_URL"]) {
    const derived = fromRedisUrl(env[key]);
    if (derived) return derived;
  }
  return null;
}

function fromRedisUrl(value) {
  if (!value) return null;
  try {
    const u = new URL(value);
    const token = decodeURIComponent(u.password || "");
    if (!token || !u.hostname) return null;
    return { base: `https://${u.hostname}`, token };
  } catch {
    return null;
  }
}

const CONN = discover();

export function configured() {
  return CONN !== null;
}

async function command(args) {
  const res = await fetch(CONN.base, {
    method: "POST",
    headers: { Authorization: `Bearer ${CONN.token}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!res.ok) {
    // Carry enough detail to diagnose without ever including the token.
    const text = (await res.text().catch(() => "")).slice(0, 200);
    throw new Error(`redis HTTP ${res.status}: ${text}`);
  }
  const body = await res.json();
  if (body.error) throw new Error(`redis: ${body.error}`);
  return body.result;
}

/** Host shape only, for diagnostics. Never the token. */
export function hostShape() {
  if (!CONN) return null;
  try {
    const h = new URL(CONN.base).hostname;
    const parts = h.split(".");
    return parts.length > 2 ? `*.${parts.slice(1).join(".")}` : h;
  } catch {
    return "unparseable";
  }
}

/** Round-trip the connection so a failure is visible rather than a blank 500. */
export async function ping() {
  try {
    const r = await command(["PING"]);
    return { ok: true, reply: String(r) };
  } catch (e) {
    return { ok: false, error: String(e.message || e).slice(0, 300) };
  }
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
