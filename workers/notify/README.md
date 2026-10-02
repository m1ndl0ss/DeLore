# Retract publisher notify (Cloudflare Worker)

Emails `contact@kandalintsev.com` when the app reports Instagram connect or Pro purchase.
Chat contents are never sent.

## Deploy

```bash
cd workers/notify
npm install
npx wrangler secret put NOTIFY_SECRET
npx wrangler secret put RESEND_API_KEY
# Optional: set a verified from-address instead of onboarding@resend.dev
npx wrangler deploy
```

Copy the worker URL into app config:

- Android `local.properties`: `NOTIFY_URL=https://retract-notify.<you>.workers.dev/v1/notify` and `NOTIFY_SECRET=…`
- iOS `Config/Secrets.xcconfig` (gitignored): `DL_NOTIFY_URL` and `DL_NOTIFY_SECRET`

If URL/secret are empty, the apps skip notify (no crash, no delay on UI).

## Body

```json
{
  "event": "instagram_connected | subscription_purchased | complimentary_unlocked",
  "instagramUsername": "handle",
  "platform": "ios | android",
  "productId": "app.delore.pro.yearly.promo",
  "promoCode": "RETRACT10",
  "occurredAt": "2026-10-02T12:00:00Z",
  "idempotencyKey": "optional-client-key"
}
```

Header: `X-Retract-Secret: <NOTIFY_SECRET>`
