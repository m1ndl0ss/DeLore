/**
 * Retract ops worker: short-lived client tokens, free-usage sync, publisher email.
 *
 * Secrets (wrangler secret put):
 *   TOKEN_SIGNING_KEY — HMAC key for client tokens (never ships in the app)
 *   RESEND_API_KEY    — https://resend.com
 *   NOTIFY_SECRET     — optional admin override for curl / scripts only (not in the app)
 *
 * Vars:
 *   NOTIFY_TO, RESEND_FROM, FREE_LIMIT
 *
 * KV: FREE_USAGE
 */
export interface Env {
  TOKEN_SIGNING_KEY: string;
  RESEND_API_KEY: string;
  NOTIFY_TO: string;
  RESEND_FROM: string;
  NOTIFY_SECRET?: string;
  FREE_LIMIT?: string;
  FREE_USAGE: KVNamespace;
}

type NotifyEvent = "instagram_connected" | "subscription_purchased" | "complimentary_unlocked";

interface NotifyBody {
  event: NotifyEvent;
  instagramUsername: string;
  platform: "ios" | "android";
  productId?: string;
  promoCode?: string;
  occurredAt?: string;
  idempotencyKey?: string;
}

type FreeUsageOp = "pull" | "sync" | "increment";

interface FreeUsageBody {
  op: FreeUsageOp;
  instagramUserId: string;
  freeUsed?: number;
  delta?: number;
  idempotencyKey?: string;
  platform: "ios" | "android";
}

interface FreeUsageRecord {
  used: number;
  updatedAt: string;
}

const MAX_BODY = 4_096;
const TOKEN_TTL_SEC = 15 * 60;
const IDEM_TTL_SEC = 90 * 24 * 60 * 60;
/** Cap how far one `sync` call can raise the server total (limits griefing via open mint). */
const SYNC_MAX_DELTA = 40;
const seen = new Map<string, number>();
const SEEN_TTL_MS = 24 * 60 * 60 * 1000;
const tokenHits = new Map<string, { count: number; windowStart: number }>();
const TOKEN_RATE_WINDOW_MS = 60_000;
const TOKEN_RATE_MAX = 10;
const writeHits = new Map<string, { count: number; windowStart: number }>();
const WRITE_RATE_WINDOW_MS = 60 * 60 * 1000;
const WRITE_RATE_MAX_IP = 60;
const WRITE_RATE_MAX_USER = 80;
const notifyHits = new Map<string, { count: number; windowStart: number }>();
const NOTIFY_RATE_WINDOW_MS = 60 * 60 * 1000;
const NOTIFY_RATE_MAX_IP = 12;

function corsHeaders(): HeadersInit {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Retract-Secret",
  };
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

function cleanUsername(raw: string): string | null {
  const trimmed = raw.trim().replace(/^@+/, "");
  if (!trimmed || trimmed.length > 64) return null;
  if (!/^[A-Za-z0-9._]+$/.test(trimmed)) return null;
  if (trimmed.toLowerCase() === "you") return null;
  return trimmed;
}

function cleanUserId(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed || trimmed.length > 64) return null;
  if (!/^[A-Za-z0-9._-]+$/.test(trimmed)) return null;
  return trimmed;
}

function freeLimit(env: Env): number {
  const parsed = Number.parseInt(env.FREE_LIMIT || "100", 10);
  if (!Number.isFinite(parsed) || parsed < 1) return 100;
  return Math.min(parsed, 10_000);
}

function clientIp(request: Request): string {
  return (
    request.headers.get("CF-Connecting-IP") ||
    request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ||
    "unknown"
  );
}

function allowRate(
  map: Map<string, { count: number; windowStart: number }>,
  key: string,
  now: number,
  windowMs: number,
  max: number,
): boolean {
  const hit = map.get(key);
  if (!hit || now - hit.windowStart > windowMs) {
    map.set(key, { count: 1, windowStart: now });
    return true;
  }
  hit.count += 1;
  return hit.count <= max;
}

function allowTokenMint(ip: string, now: number): boolean {
  return allowRate(tokenHits, ip, now, TOKEN_RATE_WINDOW_MS, TOKEN_RATE_MAX);
}

function allowWrite(ip: string, userId: string, now: number): boolean {
  return (
    allowRate(writeHits, `ip:${ip}`, now, WRITE_RATE_WINDOW_MS, WRITE_RATE_MAX_IP) &&
    allowRate(writeHits, `uid:${userId}`, now, WRITE_RATE_WINDOW_MS, WRITE_RATE_MAX_USER)
  );
}

function allowNotify(ip: string, now: number): boolean {
  return allowRate(notifyHits, ip, now, NOTIFY_RATE_WINDOW_MS, NOTIFY_RATE_MAX_IP);
}

async function ipHash(ip: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`retract-ip:${ip}`));
  return b64url(digest).slice(0, 22);
}

function pruneSeen(now: number) {
  for (const [key, at] of seen) {
    if (now - at > SEEN_TTL_MS) seen.delete(key);
  }
}

function alreadySeen(key: string, now: number): boolean {
  pruneSeen(now);
  if (seen.has(key)) return true;
  seen.set(key, now);
  return false;
}

function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = "";
  for (const b of arr) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function b64urlJson(value: unknown): string {
  return b64url(new TextEncoder().encode(JSON.stringify(value)));
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

async function mintToken(env: Env, ip: string): Promise<{ token: string; expiresAt: number }> {
  const expiresAt = Math.floor(Date.now() / 1000) + TOKEN_TTL_SEC;
  const payload = b64urlJson({
    exp: expiresAt,
    jti: crypto.randomUUID(),
    iph: await ipHash(ip),
  });
  const key = await hmacKey(env.TOKEN_SIGNING_KEY);
  const sig = b64url(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)));
  return { token: `${payload}.${sig}`, expiresAt };
}

async function verifyToken(env: Env, token: string, ip: string): Promise<boolean> {
  const parts = token.split(".");
  if (parts.length !== 2) return false;
  const [payload, sig] = parts;
  if (!payload || !sig) return false;
  try {
    const key = await hmacKey(env.TOKEN_SIGNING_KEY);
    const expected = b64url(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)));
    if (expected.length !== sig.length) return false;
    let ok = 0;
    for (let i = 0; i < expected.length; i++) ok |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
    if (ok !== 0) return false;
    const json = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/")));
    const exp = Number(json.exp);
    if (!Number.isFinite(exp) || exp <= Math.floor(Date.now() / 1000)) return false;
    // Tokens are bound to the minting IP so a stolen bearer can't be reused elsewhere.
    if (typeof json.iph !== "string" || !json.iph) return false;
    return json.iph === (await ipHash(ip));
  } catch {
    return false;
  }
}

async function authorize(request: Request, env: Env): Promise<boolean> {
  const bearer = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "").trim();
  if (bearer && env.TOKEN_SIGNING_KEY && (await verifyToken(env, bearer, clientIp(request)))) return true;
  // Admin / scripts only — never shipped in the app.
  const secret =
    request.headers.get("X-Retract-Secret") ||
    request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  return Boolean(env.NOTIFY_SECRET && secret === env.NOTIFY_SECRET);
}

function subjectFor(body: NotifyBody, username: string): string {
  switch (body.event) {
    case "instagram_connected":
      return `Retract connect @${username} (${body.platform})`;
    case "subscription_purchased":
      return `Retract Pro @${username}${body.promoCode ? ` promo ${body.promoCode}` : ""}`;
    case "complimentary_unlocked":
      return `Retract complimentary @${username}${body.promoCode ? ` ${body.promoCode}` : ""}`;
  }
}

function textFor(body: NotifyBody, username: string): string {
  const lines = [
    `Event: ${body.event}`,
    `Instagram: @${username}`,
    `Platform: ${body.platform}`,
  ];
  if (body.productId) lines.push(`Product: ${body.productId}`);
  if (body.promoCode) lines.push(`Promo: ${body.promoCode}`);
  if (body.occurredAt) lines.push(`At: ${body.occurredAt}`);
  lines.push("", "Chat contents are never sent. This is signup/ops only.");
  return lines.join("\n");
}

async function sendResend(env: Env, subject: string, text: string): Promise<Response> {
  return fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: env.RESEND_FROM,
      to: [env.NOTIFY_TO],
      subject,
      text,
    }),
  });
}

async function readUsed(env: Env, userId: string, limit: number): Promise<number> {
  try {
    const existing = await env.FREE_USAGE.get(`free:${userId}`, "json");
    if (existing && typeof (existing as FreeUsageRecord).used === "number") {
      return Math.max(0, Math.min(limit, Math.floor((existing as FreeUsageRecord).used)));
    }
  } catch {
    /* ignore */
  }
  return 0;
}

async function writeUsed(env: Env, userId: string, used: number): Promise<number> {
  const record: FreeUsageRecord = { used, updatedAt: new Date().toISOString() };
  await env.FREE_USAGE.put(`free:${userId}`, JSON.stringify(record));
  return used;
}

async function handleToken(request: Request, env: Env): Promise<Response> {
  if (!env.TOKEN_SIGNING_KEY) return json(500, { error: "misconfigured" });
  const now = Date.now();
  const ip = clientIp(request);
  if (!allowTokenMint(ip, now)) return json(429, { error: "rate_limited" });
  const minted = await mintToken(env, ip);
  return json(200, { ok: true, token: minted.token, expiresAt: minted.expiresAt });
}

async function handleNotify(request: Request, env: Env): Promise<Response> {
  const ip = clientIp(request);
  if (!allowNotify(ip, Date.now())) return json(429, { error: "rate_limited" });

  const raw = await request.text();
  if (raw.length > MAX_BODY) return json(413, { error: "too_large" });

  let body: NotifyBody;
  try {
    body = JSON.parse(raw) as NotifyBody;
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const events: NotifyEvent[] = [
    "instagram_connected",
    "subscription_purchased",
    "complimentary_unlocked",
  ];
  if (!events.includes(body.event)) return json(400, { error: "bad_event" });
  if (body.platform !== "ios" && body.platform !== "android") {
    return json(400, { error: "bad_platform" });
  }

  const username = cleanUsername(body.instagramUsername || "");
  if (!username) return json(400, { error: "bad_username" });

  const now = Date.now();
  const idem =
    (body.idempotencyKey && body.idempotencyKey.slice(0, 128)) ||
    `${body.event}:${body.platform}:${username}:${body.productId || ""}:${body.promoCode || ""}:${new Date().toISOString().slice(0, 10)}`;
  if (alreadySeen(idem, now)) {
    return json(200, { ok: true, duplicate: true });
  }

  if (!env.RESEND_API_KEY || !env.NOTIFY_TO || !env.RESEND_FROM) {
    return json(500, { error: "misconfigured" });
  }

  const mail = await sendResend(env, subjectFor(body, username), textFor(body, username));
  if (!mail.ok) {
    const detail = await mail.text().catch(() => "");
    return json(502, { error: "email_failed", detail: detail.slice(0, 200) });
  }

  return json(200, { ok: true });
}

async function handleFreeUsage(request: Request, env: Env): Promise<Response> {
  if (!env.FREE_USAGE) return json(500, { error: "misconfigured" });

  const raw = await request.text();
  if (raw.length > MAX_BODY) return json(413, { error: "too_large" });

  let body: FreeUsageBody;
  try {
    body = JSON.parse(raw) as FreeUsageBody;
  } catch {
    return json(400, { error: "invalid_json" });
  }

  if (body.platform !== "ios" && body.platform !== "android") {
    return json(400, { error: "bad_platform" });
  }
  if (body.op !== "pull" && body.op !== "sync" && body.op !== "increment") {
    return json(400, { error: "bad_op" });
  }

  const userId = cleanUserId(body.instagramUserId || "");
  if (!userId) return json(400, { error: "bad_user_id" });

  const limit = freeLimit(env);
  const stored = await readUsed(env, userId, limit);
  const ip = clientIp(request);

  if (body.op === "pull") {
    return json(200, { ok: true, freeUsed: stored });
  }

  // Mutations are rate-limited per IP + user id (open token mint otherwise lets anyone grief).
  if (!allowWrite(ip, userId, Date.now())) {
    return json(429, { error: "rate_limited", freeUsed: stored });
  }

  if (body.op === "sync") {
    const clientUsed = Number.isFinite(body.freeUsed)
      ? Math.max(0, Math.min(limit, Math.floor(body.freeUsed as number)))
      : 0;
    // Cap per-call raise so a stolen/minted token cannot jump a victim straight to the free limit.
    const raised = Math.min(clientUsed, stored + SYNC_MAX_DELTA);
    const merged = Math.max(stored, raised);
    await writeUsed(env, userId, merged);
    return json(200, { ok: true, freeUsed: merged });
  }

  // increment — one message (or small batch) with idempotency so retries don't double-count
  const delta = Number.isFinite(body.delta) ? Math.floor(body.delta as number) : 0;
  if (delta < 1 || delta > 20) return json(400, { error: "bad_delta" });
  const idem = (body.idempotencyKey || "").trim().slice(0, 128);
  if (!idem || !/^[A-Za-z0-9._:|-]+$/.test(idem)) return json(400, { error: "bad_idempotency_key" });

  const idemKey = `idem:${userId}:${idem}`;
  const prior = await env.FREE_USAGE.get(idemKey);
  if (prior != null) {
    return json(200, { ok: true, freeUsed: stored, duplicate: true });
  }

  const merged = Math.min(limit, stored + delta);
  await writeUsed(env, userId, merged);
  await env.FREE_USAGE.put(idemKey, "1", { expirationTtl: IDEM_TTL_SEC });
  return json(200, { ok: true, freeUsed: merged });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    if (request.method !== "POST") {
      return json(404, { error: "not_found" });
    }

    const url = new URL(request.url);

    if (url.pathname === "/v1/token") {
      return handleToken(request, env);
    }

    if (!(await authorize(request, env))) {
      return json(401, { error: "unauthorized" });
    }

    if (url.pathname === "/v1/notify") {
      return handleNotify(request, env);
    }
    if (url.pathname === "/v1/free-usage") {
      return handleFreeUsage(request, env);
    }

    return json(404, { error: "not_found" });
  },
};
