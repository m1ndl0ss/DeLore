/**
 * Retract publisher notify — emails contact@ when someone connects Instagram or buys Pro.
 *
 * Secrets (wrangler secret put):
 *   NOTIFY_SECRET   — shared with app BuildConfig / Info.plist
 *   RESEND_API_KEY  — https://resend.com
 *
 * Vars in wrangler.toml:
 *   NOTIFY_TO       — contact@kandalintsev.com
 *   RESEND_FROM     — verified Resend sender, e.g. Retract <notify@yourdomain.com>
 */
export interface Env {
  NOTIFY_SECRET: string;
  RESEND_API_KEY: string;
  NOTIFY_TO: string;
  RESEND_FROM: string;
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

const MAX_BODY = 4_096;
const seen = new Map<string, number>();
const SEEN_TTL_MS = 24 * 60 * 60 * 1000;

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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/v1/notify") {
      return json(404, { error: "not_found" });
    }

    const secret =
      request.headers.get("X-Retract-Secret") ||
      request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
    if (!env.NOTIFY_SECRET || secret !== env.NOTIFY_SECRET) {
      return json(401, { error: "unauthorized" });
    }

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
  },
};
