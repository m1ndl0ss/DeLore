# Promo + complimentary allowlist (`pc.json`)

Live URL (must return **JSON**, not the site SPA):

`https://kandalintsev.com/r/7f3a/pc.json`

Source of truth in this repo: [`pc.json`](pc.json).

## Decision (Matvey)

Complimentary Pro is **not** a StoreKit / Play offer code. It is a **hosted Instagram-username allowlist** in this file, plus separate **percent-off promo codes** for friends / promotion.

| Field | Purpose | Who |
|---|---|---|
| `codes` | 10% off → hidden promo SKUs (`*.promo`) | Friends / promo recipients you give a code to |
| `complimentaryUsernames` | Free Pro when that IG account logs into Retract | You + test accounts only (keep short) |
| `percentOff` | Discount percent applied when a `codes` entry matches | Default `10` |

## Edit without shipping an app update

1. Change `pc.json` here.
2. Redeploy the same bytes to `https://kandalintsev.com/r/7f3a/pc.json` (see [`docs/HOSTING_PROMPT.md`](../../HOSTING_PROMPT.md)).
3. App refetches on launch / paywall open and caches.

Rules:

- Usernames: Instagram handles, case-insensitive, **no** `@`.
- Multi-account safe: each login is checked on its own.
- Do **not** put codes or handles in the public App Store / Play listing.
- Baked fallback if the URL is down: codes `RETRACT10`, `REF10`; empty complimentary list.

## Example

```json
{
  "percentOff": 10,
  "codes": ["RETRACT10", "REF10", "FRIENDCODE"],
  "complimentaryUsernames": ["your_handle", "test_account"]
}
```
