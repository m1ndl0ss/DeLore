/**
 * Verification-code relay for the Play review Instagram account.
 *
 * email():  receives mail for review@relay.kandalintsev.com, extracts any
 *           6-8 digit code from Instagram/Meta security emails, keeps the
 *           last 5 in KV, and forwards the original to FORWARD_TO.
 * fetch():  renders the latest code at the unguessable CODE_PATH so a
 *           reviewer (who has no email access) can read it in a browser.
 */

const CODES_KEY = "review:codes";
const MAX_CODES = 5;

const pageHits = new Map();
const PAGE_RATE_WINDOW_MS = 60_000;
const PAGE_RATE_MAX = 30;

function clientIp(request) {
  return (
    request.headers.get("CF-Connecting-IP") ||
    request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ||
    "unknown"
  );
}

function allowPage(ip, now) {
  const hit = pageHits.get(ip);
  if (!hit || now - hit.windowStart > PAGE_RATE_WINDOW_MS) {
    pageHits.set(ip, { count: 1, windowStart: now });
    return true;
  }
  hit.count += 1;
  return hit.count <= PAGE_RATE_MAX;
}

/** Minimal quoted-printable decode so codes split by soft line breaks still match. */
function decodeQuotedPrintable(text) {
  return text
    .replace(/=\r?\n/g, "")
    .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
}

/**
 * Instagram/Meta security mails put the code in the subject
 * ("123456 is your Instagram code") and repeat it in the body.
 * Prefer a code next to wording about codes; fall back to any
 * standalone 6-8 digit number.
 */
function extractCode(subject, body) {
  const contextual = /(\d{6,8})\s+is\s+your|code[^0-9]{0,20}(\d{6,8})|(\d{6,8})[^0-9]{0,20}code/i;
  const bare = /(?<!\d)(\d{6,8})(?!\d)/;
  for (const source of [subject, body]) {
    if (!source) continue;
    const ctx = source.match(contextual);
    if (ctx) return ctx[1] || ctx[2] || ctx[3];
  }
  for (const source of [subject, body]) {
    if (!source) continue;
    const m = source.match(bare);
    if (m) return m[1];
  }
  return null;
}

async function storeCode(env, entry) {
  let codes = [];
  try {
    codes = (await env.FREE_USAGE.get(CODES_KEY, "json")) || [];
  } catch {
    /* start fresh */
  }
  codes.unshift(entry);
  await env.FREE_USAGE.put(CODES_KEY, JSON.stringify(codes.slice(0, MAX_CODES)));
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function renderPage(latest) {
  const body = latest
    ? `<div class="code">${escapeHtml(latest.code)}</div>
       <p class="age">arrived ${escapeHtml(latest.ageText)}</p>
       <p class="subject">${escapeHtml(latest.subject || "")}</p>`
    : `<div class="code none">······</div>
       <p class="age">No code received yet — this page refreshes automatically.</p>`;
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta http-equiv="refresh" content="10" />
  <meta name="robots" content="noindex, nofollow" />
  <title>Retract review — verification code</title>
  <style>
    body { font-family: ui-sans-serif, system-ui, sans-serif; max-width: 26rem; margin: 15vh auto 0; padding: 0 1.25rem; text-align: center; color: #161022; }
    .code { font-size: 4rem; font-weight: 800; letter-spacing: 0.12em; margin: 1.5rem 0 0.5rem; font-variant-numeric: tabular-nums; }
    .code.none { color: #b7b2c6; }
    .age { color: #3d3750; margin: 0 0 0.25rem; }
    .subject { color: #8a84a0; font-size: 0.85rem; overflow-wrap: anywhere; }
    .note { margin-top: 2.5rem; color: #3d3750; font-size: 0.95rem; border-top: 1px solid #e4e1ee; padding-top: 1rem; }
  </style>
</head>
<body>
  <p>Latest code for the review Instagram account</p>
  ${body}
  <p class="note">Use this code when Instagram asks for email verification. The page refreshes every 10 seconds.</p>
</body>
</html>`;
}

function ageText(receivedAt, now) {
  const minutes = Math.max(0, Math.round((now - receivedAt) / 60_000));
  if (minutes === 0) return "less than a minute ago";
  if (minutes === 1) return "1 minute ago";
  return `${minutes} minutes ago`;
}

export default {
  async email(message, env, ctx) {
    const subject = message.headers.get("subject") || "";
    let rawBody = "";
    try {
      rawBody = await new Response(message.raw).text();
    } catch {
      /* subject-only extraction still works */
    }
    const code = extractCode(subject, decodeQuotedPrintable(rawBody));
    if (code) {
      await storeCode(env, {
        code,
        receivedAt: Date.now(),
        subject: subject.slice(0, 200),
      });
    }
    // Keep a copy in the ops inbox regardless of whether a code was found.
    if (env.FORWARD_TO) {
      try {
        await message.forward(env.FORWARD_TO);
      } catch (error) {
        console.log(`forward failed: ${error}`);
      }
    }
  },

  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "GET" || url.pathname !== env.CODE_PATH) {
      return new Response("not found", { status: 404 });
    }
    const now = Date.now();
    if (!allowPage(clientIp(request), now)) {
      return new Response("rate limited — try again in a minute", { status: 429 });
    }
    let codes = [];
    try {
      codes = (await env.FREE_USAGE.get(CODES_KEY, "json")) || [];
    } catch {
      /* render empty state */
    }
    const latest = codes[0]
      ? { ...codes[0], ageText: ageText(codes[0].receivedAt, now) }
      : null;
    return new Response(renderPage(latest), {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "X-Robots-Tag": "noindex, nofollow",
      },
    });
  },
};
