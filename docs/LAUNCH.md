# Retract launch checklist

Support email: **contact@kandalintsev.com**

Privacy, FAQ, and Terms ship **in-app** on iOS and Android. Store consoles still
need a public HTTPS privacy policy URL. Host the HTML in `docs/legal/` at:

- https://kandalintsev.com/retract/privacy
- https://kandalintsev.com/retract/terms
- Support URL can be `mailto:contact@kandalintsev.com` or a hosted FAQ page

Until those URLs are live, App Store / Play submission will fail the privacy-policy
check even though the app itself no longer opens a browser for Terms or Support.

## Store listing

Copy UnSendAll’s honest framing, not their stealth language. They shipped iOS
as Social Networking by saying they automate Instagram’s Unsend, log in on
instagram.com, and keep the session on device.

**Name:** Retract  
**Subtitle:** Unsend the DMs you sent  
**Category:** Social Networking  

**Promotional text (170):**  
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
**Privacy:** hosted copy of `docs/legal/privacy.html`  
**Age rating:** 12+ / Teen (user-generated social content via Instagram)

## App Store Connect

1. Bundle ID `app.delore.ios` (or your own). Set `DEVELOPMENT_TEAM` in `Config/Base.xcconfig`.
2. One subscription group **Retract Pro**. Create four auto-renewable products (do not submit the leftover one-time ID):
   - `app.delore.pro.monthly` — $19.99 / month
   - `app.delore.pro.yearly` — $59.99 / year
   - `app.delore.pro.monthly.promo` — $17.99 / month (10% off; hidden from the paywall)
   - `app.delore.pro.yearly.promo` — $53.99 / year (10% off; hidden from the paywall)
   Paywall only shows monthly + yearly. `RETRACT10` and `REF10` buy the promo SKU. Until those promo products exist in the console, a redeemed 10% code will not start a charge.
   Do not submit `app.delore.cleanup.single` for review.
3. App Privacy nutrition label: declare Instagram username (User ID / Other User Content) collected for App Functionality — emailed to the publisher on connect and purchase (with promo code if any). Do **not** claim Data Not Collected. Chat contents / message text are not collected. Instagram still receives the same website traffic as unsending in a browser.
4. Review notes:
   - Login is Instagram’s own website (instagram.com) in-app. Session stays on device.
   - Unsend is Instagram’s own Unsend, driven from this phone.
   - Reviewers do not need an Instagram account. If Instagram login or Terms appear, tap the Retract wordmark **seven times** (or VoiceOver: Load sample inbox). That loads fake chats and never contacts Instagram. Pick a chat, retract, and the paywall appears after 100 free unsends.
   - Login chrome says “Continue on Instagram.com”, not “Sign in with Instagram”.
   - Paywall shows Restore, Terms, Privacy, and auto-renew / manage-cancel fine print next to the Subscribe buttons.
   - Terms disclose that unofficial tools may violate Instagram’s Terms of Use, plus App Store auto-renew and Apple-not-a-party language. Privacy describes sample data.
   - Promo products exist for 10% checkout codes and are not listed on the paywall.
5. Export compliance: `ITSAppUsesNonExemptEncryption` is already `false`.
6. Archive Release, upload, TestFlight sandbox purchases.

## Play Console

UnSendAll is not on Play. Sister apps UnLikeAll / UnRepostAll are, with the same local-automation listing. Retract can still ship Android if the listing stays third-party and local.

1. `applicationId` `app.delore.android` (keep unless you are ready to migrate).
2. Create the same four subscription products in one base-plan group at $19.99 / $59.99 / $17.99 / $53.99. Do not list `app.delore.cleanup.single`.
3. Data safety: declare Instagram username collected for app functionality (emailed to publisher on connect / purchase; promo code if used). Chat contents not collected. Instagram receives website traffic from the device.
4. Upload an AAB from `:app:bundleRelease`, content rating, license testers. Declare the existing `dataSync` foreground service in Play App content if the console asks.
5. Privacy policy URL must be the hosted HTML. Support email: contact@kandalintsev.com.
6. Review notes: same hidden wordmark path as iOS. Reviewers can complete the flow without Instagram.

## What is already in the binary

- In-app FAQ (Support). Email fallback `contact@kandalintsev.com`.
- In-app Terms of use (Settings, paywall). Does not open a browser.
- In-app Privacy.
- Sample inbox for App Review (seven taps on the Retract wordmark; not shown on the home screen).
- Paywall promo field. Issued codes `RETRACT10` and `REF10` take 10% off by purchasing the promo SKU. Three guesses per day.
- Unsend via website GraphQL then same-origin i.instagram.com delete. See `docs/instagram-unsend.md`.

## Do not change for launch

- Kotlin package `app.delore.android` and `applicationId`
- StoreKit / Play product IDs `app.delore.cleanup.single`, `app.delore.pro.monthly`, `app.delore.pro.yearly`, `app.delore.pro.monthly.promo`, `app.delore.pro.yearly.promo`
- Desktop Chrome user-agent (do not spoof the Instagram app)
