# Retract — App Review notes

Paste into **App Store Connect → App Review Information → Notes** and **Google Play → Store listing / App content notes** (or the review reply field). Same text works on both stores.

---

## Copy-paste block

```
Retract automates Instagram’s built-in Unsend for DMs the signed-in user sent. It is not affiliated with Instagram or Meta.

HOW TO REVIEW
1. Tap Connect Instagram and sign in on Instagram's own page with the
   provided Instagram test account (username: apptesting070124; password in
   the console's app-access / login-credentials field).
2. If Instagram asks for an email verification code during login, open
   https://kandalintsev.com/r/EtMJ0fotbnFzpKmB/code in any browser; it shows
   the latest code sent to this account's email (refreshes automatically).
3. Pick one or more chats → continue → start retracting. Unsends run at a
   conservative, human-like pace by design.
4. After 100 free unsends, the Pro paywall appears (monthly and yearly). Restore, Terms, Privacy, and auto-renew / manage-cancel fine print are on the paywall. Manage or cancel is also in Settings.

IF INSTAGRAM BLOCKS THE LOGIN
If the test account is checkpointed, rate-limited, or otherwise cannot sign in,
you can review the full flow against a local sample inbox (fake chats; nothing
touches Instagram). It is intentionally hidden so normal users never reach it:

1. On the logged-out welcome screen, press and hold the "retract." wordmark
   (top-left) for 3 seconds, then release.
2. Within 5 seconds, tap the "Connect Instagram" button 5 times.
3. A dialog appears: "Reviewer sample inbox — this is local demo data, nothing
   touches Instagram." Tap Continue.
4. Pick chats → continue → start retracting. A "Sample inbox (reviewer mode)"
   banner stays at the top and Settings shows "Demo". Demo cleanups run at the
   same pace as real ones. Killing the app exits demo (it is never persisted).

LOGIN (LIVE ACCOUNT PATH)
• Sign-in uses Instagram’s own website (instagram.com) inside the app — chrome says “Continue on Instagram.com”, not “Sign in with Instagram”.
• Session cookies stay on the device (Keychain / encrypted storage). We never see or store the password.
• Unsend is Instagram’s own Unsend, triggered from this phone over Instagram’s website session (desktop Chrome user-agent; we do not spoof the Instagram mobile app).

WHAT WE COLLECT
• We never read chat message text. Message text never leaves the phone and is never sent to us.
• When a user connects Instagram or buys Pro, the app emails the publisher the Instagram username (and any promo code used on purchase) for signup/ops only. Declared in App Privacy / Data safety as App Functionality — not tracking. No analytics SDK, no ads.

SUBSCRIPTIONS
• Product group: Retract Pro.
• Visible on paywall: app.retract.pro.monthly, app.retract.pro.yearly.
• Hidden promo SKUs (10% codes): app.retract.pro.monthly.promo, app.retract.pro.yearly.promo — not listed on the paywall.
• Do not review the unused one-time ID app.retract.cleanup.single (not submitted).

PRIVACY / TERMS
• https://kandalintsev.com/retract/privacy
• https://kandalintsev.com/retract/terms
• Also available in-app under Settings.

SUPPORT
• contact@kandalintsev.com
```

---

## Screenshots to attach (both stores)

1. Home / chat picker with a live inbox  
2. Cleanup / unsending progress  
3. Paywall showing monthly + yearly only (with Restore + legal links + auto-renew fine print)  
4. Settings (Instagram connected / Log out, Plan, Privacy, Terms)
