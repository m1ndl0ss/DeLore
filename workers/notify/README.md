# Retract publisher notify (Cloudflare Worker)

Emails `contact@kandalintsev.com` when the app reports Instagram connect or Pro purchase.
Tracks **free-unsends usage** per Instagram user id (KV), including per-message increments
so a reinstall still sees prior usage.

Chat contents are never sent.

## Auth

The app **does not** ship `NOTIFY_SECRET`.

1. `POST /v1/token` (unauthenticated, IP rate-limited) → short-lived HMAC bearer token **bound to the minting IP**  
2. `POST /v1/notify` and `POST /v1/free-usage` require `Authorization: Bearer <token>` from the same IP  
3. Mutations are rate-limited per IP / user id; notify is rate-limited per IP  

Worker secrets (never in the app):

- `TOKEN_SIGNING_KEY` — HMAC key for tokens  
- `RESEND_API_KEY` — Resend  
- `NOTIFY_SECRET` — optional admin override for curl/scripts only  

## Deploy

```bash
cd workers/notify
npm install
npx wrangler secret put TOKEN_SIGNING_KEY
npx wrangler secret put RESEND_API_KEY
# optional admin curl secret (not for the app):
# npx wrangler secret put NOTIFY_SECRET
npx wrangler deploy
```

App config (URL only):

- Android `local.properties`: `NOTIFY_URL=https://retract-notify.<you>.workers.dev/v1/notify`
- iOS `Config/Secrets.xcconfig`: `DL_NOTIFY_URL=…`

Empty URL disables notify **and** free-usage sync (local counter still works on-device).

## Free usage

| op | body | effect |
|---|---|---|
| `increment` | `instagramUserId`, `delta` (1–20), `idempotencyKey` | add once per key |
| `sync` | `instagramUserId`, `freeUsed` | max-merge; each call may raise by at most 40 |
| `pull` | `instagramUserId` | read server total |

Response: `{ "ok": true, "freeUsed": N }`

Clients loop `sync` until the local total is fully pushed. This caps griefing if someone mints a token and writes another user's id.

## Notify body

```json
{
  "event": "instagram_connected | subscription_purchased | complimentary_unlocked",
  "instagramUsername": "handle",
  "platform": "ios | android",
  "productId": "app.retract.pro.yearly.promo",
  "promoCode": "RETRACT10",
  "occurredAt": "2026-10-02T12:00:00Z",
  "idempotencyKey": "optional-client-key"
}
```
