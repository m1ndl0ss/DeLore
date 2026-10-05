# Full hosting prompt — Retract (legal, promos, free Pro, free-usage sync)

Copy **everything below the horizontal rule** into another agent. Give it access to:

1. The **website repo** that deploys `kandalintsev.com` (static legal + `pc.json`)
2. Optionally the **Retract app repo** `https://github.com/m1ndl0ss/DeLore` branch `feature/delore-mvp` (source files + Cloudflare worker under `workers/notify/`)

Ask Matvey before destructive live-site changes. Do not invent Instagram usernames — he will supply handles for the free-Pro allowlist.

---

# Task: Host everything Retract needs online

You are setting up / fixing **all remote hosting** for the Retract (DeLore) app so store submission and production work.

There are **two separate systems**:

| System | What it hosts | Where |
|---|---|---|
| **A. Static files on kandalintsev.com** | Privacy, Terms, promo codes, free-Pro Instagram allowlist | Website / SPA project for `kandalintsev.com` |
| **B. Cloudflare Worker `retract-notify`** | Publisher emails + **free unsends used / left** per Instagram user id | Retract repo → `workers/notify/` |

Do **not** put free-usage counters in the static JSON. That lives in Worker KV.  
Do **not** put promo codes or free-Pro handles on any public marketing page or store listing.

Source of truth for static files (Retract repo):

- `docs/legal/privacy.html`
- `docs/legal/terms.html`
- `docs/legal/faq.html` (optional)
- `docs/r/7f3a/pc.json`
- Docs: `docs/LAUNCH.md`, `docs/r/7f3a/README.md`, `workers/notify/README.md`

---

## Part A — Static site (`kandalintsev.com`)

### Problem today

These URLs often **HTTP 200 with the personal-site SPA shell** (`Matvei Kandalintsev` Vite/React `index.html`). That is **wrong**. Apple/Google need real privacy HTML. The app `JSON.parse`s `pc.json` — HTML breaks promos and free Pro.

### Required URLs (must return file bodies, not SPA)

| Live URL | Source in Retract repo | Content-Type |
|---|---|---|
| `https://kandalintsev.com/retract/privacy` | `docs/legal/privacy.html` | `text/html; charset=utf-8` |
| `https://kandalintsev.com/retract/terms` | `docs/legal/terms.html` | `text/html; charset=utf-8` |
| `https://kandalintsev.com/r/7f3a/pc.json` | `docs/r/7f3a/pc.json` | `application/json; charset=utf-8` |

Optional:

| `https://kandalintsev.com/retract/faq` | `docs/legal/faq.html` |

### `pc.json` — promo codes + free Pro Instagram allowlist

Shape:

```json
{
  "percentOff": 10,
  "codes": ["RETRACT10", "REF10"],
  "complimentaryUsernames": ["matvey_ig_handle", "test_account"]
}
```

| Field | Meaning | Who |
|---|---|---|
| `codes` | Percent-off promo codes typed on the in-app paywall. Charges hidden store SKUs `app.retract.pro.monthly.promo` / `app.retract.pro.yearly.promo` at 10% off | Friends / promotion — Matvey hands out codes |
| `complimentaryUsernames` | Instagram usernames that get **Pro for free** when they log into Retract (case-insensitive, **no** `@`) | Matvey + test accounts only |
| `percentOff` | Discount percent for `codes` (default 10) | — |

**Decided product policy:** complimentary Pro is this hosted allowlist — **not** Apple/Google offer codes.

Rules:

- Ask Matvey for the exact Instagram handles to put in `complimentaryUsernames`. Do not guess.
- Keep `codes` as the list he actually gives friends (`RETRACT10`, `REF10`, plus any new ones he wants).
- Do **not** link `pc.json` from nav, footer, sitemap, or robots highlights. Obscure path is intentional.
- Cache: short / revalidate for `pc.json` (edits must go live without an app update). Legal pages can cache longer.
- CORS: GET is enough; `Access-Control-Allow-Origin: *` on `pc.json` is OK if needed.
- App baked fallback if URL is down: codes `RETRACT10`/`REF10`, **empty** complimentary list.

### How to host (website repo)

1. Pull/sync the HTML/JSON from Retract `m1ndl0ss/DeLore` (`feature/delore-mvp` or latest).
2. Serve as static files that **beat the SPA catch-all** (e.g. `public/retract/privacy.html`, `public/r/7f3a/pc.json` + rewrites so `/retract/privacy` is not `index.html`).
3. Canonical URLs without forcing a marketing landing page for Retract.
4. No promo codes on public site copy.

### Verify Part A (fail if SPA)

```bash
curl -s https://kandalintsev.com/retract/privacy | head -n 8
# Expect title: Retract — Privacy  (NOT "Matvei Kandalintsev")

curl -s https://kandalintsev.com/retract/terms | head -n 8
# Expect title: Retract — Terms of use

curl -s https://kandalintsev.com/r/7f3a/pc.json
# Expect parseable JSON with percentOff, codes, complimentaryUsernames
python -c "import json,urllib.request; print(json.load(urllib.request.urlopen('https://kandalintsev.com/r/7f3a/pc.json')))"
```

Reject deploy if body contains `/assets/index-` or the personal portfolio title.

### Done when (Part A)

- Privacy/Terms readable with JS disabled and usable as store Privacy Policy / Terms URLs.
- `pc.json` is real JSON with Matvey’s codes + complimentary IG handles filled in as he specified.
- Nothing about codes/allowlist appears on the public marketing site.

---

## Part B — Cloudflare Worker (free messages left + notify emails)

This is **not** the static website. It is the worker in the Retract repo:

`workers/notify/` (wrangler name `retract-notify`)

### What it does

1. **Notify** — emails `contact@kandalintsev.com` on Instagram connect / Pro purchase / complimentary unlock (username + platform + product/promo only — **never** chat text).
2. **Free usage** — stores how many of the **100 free unsends** each Instagram user id has already used in KV (`FREE_USAGE`), so reinstall / new phone cannot refill the free tier.

Free tier math (app + worker):

- Lifetime free limit: **100** unsends (`FREE_LIMIT` in worker vars / app config).
- Server tracks `freeUsed` per `instagramUserId`.
- Messages left ≈ `max(0, 100 - freeUsed)` (Pro users ignore free limit).

### API (app uses these)

Auth: app mints a short-lived IP-bound bearer via `POST /v1/token` (no secret in the binary). Then:

| Endpoint | Purpose |
|---|---|
| `POST /v1/token` | Mint bearer (IP rate-limited) |
| `POST /v1/notify` | Publisher email events |
| `POST /v1/free-usage` | `op`: `pull` \| `sync` \| `increment` |

Free-usage body examples:

```json
{ "op": "pull", "instagramUserId": "62899…", "platform": "ios" }
{ "op": "sync", "instagramUserId": "62899…", "freeUsed": 12, "platform": "android" }
{ "op": "increment", "instagramUserId": "62899…", "delta": 1, "idempotencyKey": "…", "platform": "ios" }
```

Response: `{ "ok": true, "freeUsed": N }`

Hardening already in worker (do not weaken):

- Tokens bound to minting IP
- `sync` max raise per call capped (`SYNC_MAX_DELTA` ≈ 40); clients loop until caught up
- Rate limits on write/notify
- Chat contents never accepted

### Deploy Part B

From Retract repo:

```bash
cd workers/notify
npm install
npx wrangler secret put TOKEN_SIGNING_KEY
npx wrangler secret put RESEND_API_KEY
# optional admin-only: npx wrangler secret put NOTIFY_SECRET
npx wrangler deploy
```

Worker config notes (`wrangler.toml`):

- `NOTIFY_TO = contact@kandalintsev.com`
- `RESEND_FROM = Retract <notify@kandalintsev.com>` (needs verified Resend domain)
- `FREE_LIMIT = "100"`
- KV binding `FREE_USAGE`

### Wire the app (after worker URL exists)

Empty notify URL disables **both** emails and free-usage sync (local counter still works on one device only).

- Android `local.properties` / release secrets: `NOTIFY_URL=https://retract-notify.<account>.workers.dev/v1/notify`  
  (free-usage client derives `/v1/free-usage` and `/v1/token` from the same host)
- iOS `Config/Secrets.xcconfig`: `DL_NOTIFY_URL=…` same pattern

Confirm with Matvey before putting production URLs into release configs. Do not commit real secrets.

### Verify Part B

```bash
# health / token mint (expect JSON token, not HTML)
curl -sS -X POST https://retract-notify.<account>.workers.dev/v1/token \
  -H 'content-type: application/json' -d '{}'

# pull free usage with returned bearer (expect freeUsed number)
curl -sS -X POST https://retract-notify.<account>.workers.dev/v1/free-usage \
  -H "authorization: Bearer <token>" \
  -H 'content-type: application/json' \
  -d '{"op":"pull","instagramUserId":"test-user","platform":"ios"}'
```

### Done when (Part B)

- Worker deployed with secrets set.
- `FREE_USAGE` KV bound.
- Token + free-usage pull/sync work.
- Resend can mail `contact@kandalintsev.com` (domain verified) **or** Matvey explicitly defers notify emails (free-usage can still run).
- App release configs pointed at the worker URL when Matvey is ready.

---

## What you are NOT doing

- No Retract marketing landing page required for store submit.
- No StoreKit / Play offer-code setup for complimentary Pro (allowlist only).
- Do not submit / create `app.retract.cleanup.single`.
- Do not spoof Instagram app user-agent (app keeps desktop Chrome UA).
- Do not list promo codes or complimentary usernames in App Store / Play public copy.
- Do not change Android `applicationId` `app.retract.android`.
- Do not weaken worker auth / sync caps.

---

## Store console items that depend on this hosting (remind Matvey; don’t invent console actions unless asked)

After Part A is live:

- Privacy URL in App Store Connect + Play: `https://kandalintsev.com/retract/privacy`
- Terms URL where required: `https://kandalintsev.com/retract/terms`

Still Matvey’s console work (not hosting): create four Retract Pro IAPs, listing, privacy nutrition / Data safety, review notes from `docs/REVIEW_NOTES.md`, TestFlight / Play license-tester purchases.

---

## Report back

1. Deploy commits / Worker URL.
2. Curl snippets proving privacy, terms, and `pc.json` are **not** the SPA.
3. Final `pc.json` contents (codes + complimentary usernames as Matvey approved).
4. Worker: token + free-usage pull result.
5. Whether notify email was verified or deferred.
6. Any blockers (Resend domain, SPA routing, missing IG handles from Matvey).
