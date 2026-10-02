# Retract launch checklist (Matvey)

Support: **contact@kandalintsev.com**  
Legal source of truth: `docs/legal/` → host before submit:

| URL | File |
|---|---|
| https://kandalintsev.com/retract/privacy | `docs/legal/privacy.html` |
| https://kandalintsev.com/retract/terms | `docs/legal/terms.html` |

Ask before editing the live site. Until those URLs return 200, store submission fails.

### Do you need a website?

**Not a marketing site.** Apple and Google require a *public HTTPS privacy policy URL* on the listing. Play and many regions also expect public Terms. In-app Terms/Privacy are not enough for the console forms — reviewers and users must open the URL without installing the app.

Minimum: host the two static files from `docs/legal/` at the URLs above (any static host is fine). No landing page, blog, or product site required.

**Reviewer paste text:** [`docs/REVIEW_NOTES.md`](REVIEW_NOTES.md)  
**Unsend engineering:** [`docs/instagram-unsend.md`](instagram-unsend.md)  
**Publisher notify (optional ops):** [`workers/notify/README.md`](../workers/notify/README.md)

---

## Pre-submit order

1. Host privacy + terms (200).
2. Create IAP products in both consoles (below).
3. Fill listing + age + privacy nutrition / Data safety.
4. Paste review notes from `REVIEW_NOTES.md`.
5. Attach paywall IAP screenshots.
6. Decide complimentary Pro: stay internal gift vs StoreKit / Play offer code (Guideline 3.1.1).
7. iOS: Archive **Release** → TestFlight sandbox purchase.  
   Android: `:app:bundleRelease` AAB → content rating → license testers.
8. Deploy notify worker + put secrets in release builds if you want connect/purchase emails (app works with empty notify URL).

---

## Store listing (public — no promo / complimentary codes)

**Name:** Retract  
**Subtitle:** Unsend the DMs you sent  
**Category:** Social Networking  
**Age:** 12+ / Teen  

**Promotional text (≤170):**  
Retract automates Instagram’s Unsend on this phone. Sign in on Instagram’s own page. We never see your password. Not affiliated with Meta.

**Description:**

Retract unsends Instagram direct messages you sent. Sign in on Instagram’s own page, pick chats, and Retract automates Unsend from this phone. Login stays on this device. Retract is not affiliated with Instagram or Meta. Use is at your own risk.

• Only messages you sent. Messages from other people are never touched.  
• We never read your chats. Message text stays on this phone.  
• Login stays on this device. No analytics SDK. No ads.  
• 100 unsends free. Pro is unlimited, billed as monthly or yearly through the store.  
• Not affiliated with Instagram or Meta. We are not responsible for anything that happens to your account.

Retract is a cleanup tool. It does not collect passwords, bypass Instagram security checks, or read chats on a server. Connecting Instagram or buying Pro emails the publisher your Instagram username (and promo code if used) for signup ops only — never chat contents.

**Keywords (iOS):** unsend, instagram, dm, cleanup, delete messages, retract, privacy  

**Support:** contact@kandalintsev.com  
**Privacy URL:** https://kandalintsev.com/retract/privacy  

No stealth / detection language. Do not mention sample inbox or unlock codes in the listing.

---

## In-app purchases (both stores)

One subscription group: **Retract Pro**. Four auto-renewables:

| Product ID | Price | Paywall |
|---|---|---|
| `app.delore.pro.monthly` | $19.99 / month | Shown |
| `app.delore.pro.yearly` | $59.99 / year | Shown |
| `app.delore.pro.monthly.promo` | $17.99 / month | Hidden (10% codes) |
| `app.delore.pro.yearly.promo` | $53.99 / year | Hidden (10% codes) |

Do **not** submit `app.delore.cleanup.single`.  
In-app codes `RETRACT10` / `REF10` purchase the promo SKUs (three guesses/day). Until promo products exist in the console, those codes will not charge.

---

## App Privacy / Play Data safety

Do **not** claim “Data Not Collected.”

Declare (App Functionality, not used for tracking):

- Instagram username (User ID / other user content) — emailed to publisher on Instagram connect and on Pro purchase  
- Promo code string when used at purchase  
- Purchases handled by Apple / Google (card number not received by Retract)

Do **not** declare DM message text, inbox contents, or analytics identifiers.  
Instagram still receives the same website traffic as unsending in a browser.  
Play: declare `dataSync` foreground service if the console asks.

---

## App Store Connect checklist

1. Bundle ID `app.delore.ios`. Set `DEVELOPMENT_TEAM` in `Config/Base.xcconfig`.
2. Subscription group + four products above.
3. Nutrition label as in previous section.
4. Paste [`REVIEW_NOTES.md`](REVIEW_NOTES.md).
5. IAP screenshots of in-app paywall (monthly + yearly only).
6. `ITSAppUsesNonExemptEncryption` = false (already set).
7. Archive Release → upload → TestFlight sandbox buy (monthly and yearly; optionally promo SKU).

---

## Play Console checklist

1. Keep `applicationId` `app.delore.android`.
2. Same four subscription products / base plans.
3. Data safety as above.
4. `:app:bundleRelease` AAB, content rating, license testers.
5. Privacy URL + support email.
6. Same review notes as iOS. Declare `dataSync` FGS if asked.

---

## What ships in the binary

- In-app FAQ, Terms, Privacy (no browser required for those).
- Instagram.com WebView login; Settings → Instagram → Connect / Log out.
- Sample inbox for review only (seven taps on Retract wordmark / “Load sample inbox”).
- 100 free unsends → Pro paywall with Restore + auto-renew fine print.
- GraphQL-only Unsend on `www.instagram.com` (no REST delete). See `instagram-unsend.md`.
- Optional fire-and-forget notify to publisher (username / purchase / promo). Empty URL = disabled.
- Terms acceptance version 3 (re-prompt after privacy disclosure update).

---

## Do not change at launch

- Android package / `applicationId` `app.delore.android`
- Product IDs listed above
- Desktop Chrome user-agent (never spoof the Instagram app)
