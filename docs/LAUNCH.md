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

**Name:** Retract  
**Subtitle:** Take back the DMs you sent  
**Category:** Social / Lifestyle  

**Promotional text (170):**  
Unsend the Instagram DMs you sent — in bulk, on this phone. Sign in on Instagram’s own page. We never see your password.

**Description:**

Retract helps you unsend Instagram direct messages you sent. Connect through Instagram’s own sign-in page, pick chats, and Retract unsends from this phone — slowly, because Instagram rate-limits. Use is at your own risk. Retract is not responsible for bans, locks, or anything Instagram does to your account.

• Only messages you sent. Messages from other people are never touched.  
• Login stays on this device. No Retract server. No analytics. No ads.  
• 100 unsends free. Pro is unlimited, billed as monthly or yearly through the store.  
• Not affiliated with Instagram or Meta. We are not responsible for anything that happens to your account.

Retract is a cleanup tool. It does not collect passwords, bypass Instagram security checks, or read chats on a server.

**Keywords (iOS):** unsend, instagram, dm, cleanup, delete messages, retract, privacy

**Support:** contact@kandalintsev.com  
**Privacy:** hosted copy of `docs/legal/privacy.html`  
**Age rating:** 12+ / Teen (user-generated social content via Instagram)

## App Store Connect

1. Bundle ID `app.delore.ios` (or your own). Set `DEVELOPMENT_TEAM` in `Config/Base.xcconfig`.
2. IAP products (must match StoreKit file). Submit only the subscriptions:
   - `app.delore.pro.monthly` — auto-renew $19.99 / month
   - `app.delore.pro.yearly` — auto-renew $59.99 / year  
   Same subscription group. Review screenshots of the in-app paywall (monthly + yearly only).
   Do not submit `app.delore.cleanup.single` for review; the ID stays in the binary for old purchases.
3. App Privacy nutrition label: Data Not Collected by Retract. Instagram receives the same website traffic the user would generate by unsending in a browser.
4. Review notes: login is Instagram’s website in-app; session stays on device; Unsend is Instagram’s own action; Terms and Privacy are in-app; support email above.
5. Export compliance: `ITSAppUsesNonExemptEncryption` is already `false`.
6. Archive Release, upload, TestFlight sandbox purchases.

## Play Console

1. `applicationId` `app.delore.android` (keep unless you are ready to migrate).
2. Create `app.delore.pro.monthly` and `app.delore.pro.yearly` in Play Billing at $19.99 / $59.99. Do not list `app.delore.cleanup.single`.
3. Data safety: data not collected by Retract. Instagram receives website traffic from the device.
4. Upload an AAB from `:app:bundleRelease`, content rating, license testers. Declare the existing `dataSync` foreground service in Play App content if the console asks.
5. Privacy policy URL must be the hosted HTML. Support email: contact@kandalintsev.com.

## What is already in the binary

- In-app FAQ (Support). Email fallback `contact@kandalintsev.com`.
- In-app Terms of use (Settings, paywall). Does not open a browser.
- In-app Privacy.
- Paywall promo field. Campaign codes take 10% off listed prices. Three guesses per day.
- Unsend via website GraphQL then same-origin i.instagram.com delete. See `docs/instagram-unsend.md`.

## Do not change for launch

- Kotlin package `app.delore.android` and `applicationId`
- StoreKit / Play product IDs `app.delore.cleanup.single`, `app.delore.pro.monthly`, `app.delore.pro.yearly`
- Desktop Chrome user-agent (do not spoof the Instagram app)
