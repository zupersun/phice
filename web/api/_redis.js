// Redis access for the signaling letterbox.
//
// The Vercel marketplace provisions Redis Cloud, which speaks the normal Redis
// protocol and has no REST API -- so this talks TCP with node-redis rather than
// fetch. A connection per invocation is wasteful in general, but signaling is two
// requests per pairing, so it costs nothing that matters and avoids holding a
// socket across a serverless freeze.
import { createClient } from "redis";

function url() {
  const env = process.env;
  return (
    env.KV_REDIS_URL || env.REDIS_URL || env.KV_URL ||
    env.UPSTASH_REDIS_URL || env.DATABASE_URL || null
  );
}

export function configured() {
  return Boolean(url());
}

/** Host shape only, for diagnostics. Never credentials. */
export function hostShape() {
  const u = url();
  if (!u) return null;
  try {
    const h = new URL(u).hostname.split(".");
    return h.length > 2 ? `*.${h.slice(1).join(".")}` : h.join(".");
  } catch {
    return "unparseable";
  }
}

async function withClient(fn) {
  const client = createClient({ url: url(), socket: { connectTimeout: 5000 } });
  client.on("error", () => {});  // surfaced by the await below, not by the emitter
  await client.connect();
  try {
    return await fn(client);
  } finally {
    client.destroy();
  }
}

/** Store a JSON value under `key`, expiring after `seconds`. */
export async function setJson(key, value, seconds) {
  await withClient((c) => c.set(key, JSON.stringify(value), { EX: seconds }));
}

/** Read a JSON value, or null if absent or unreadable. */
export async function getJson(key) {
  const raw = await withClient((c) => c.get(key));
  if (raw == null) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export async function del(key) {
  await withClient((c) => c.del(key));
}

/** Round-trip the connection so a failure is visible rather than a blank 500. */
export async function ping() {
  try {
    return { ok: true, reply: String(await withClient((c) => c.ping())) };
  } catch (e) {
    return { ok: false, error: String(e.message || e).slice(0, 300) };
  }
}
