# DeLore

**Delete the lore.** A Gen-Z app for cleaning up the Instagram DMs *you* sent, in bulk, slowly and safely. iOS and Android clients live in this repo and follow the same product: Instagram-hosted login, on-device session, local unsend.

> Instagram has no official consumer DM-unsend API. DeLore still performs the core action the same
> way a live App Store competitor (UnSendAll) describes for iOS: the user signs in through
> Instagram's own website, the session stays on the phone, and Unsend runs locally against that
> session. We do **not** collect passwords, spoof a mobile app identity, solve checkpoints, or
> send DMs to a DeLore server.
>
> - **Every build:** Instagram-hosted login (WKWebView) → Keychain session → inbox discovery → the
>   existing cleanup engine → website Unsend, with conservative pacing. Test on a real account.

## What the app does

1. **Welcome:** "Delete the lore." / "Get started".
2. **Connect Instagram:** the user signs in on Instagram's own page. We never see the password.
3. **Home:** "Your DMs · 8,923" (the messages *you* sent), plus **Clean up**, **Choose chats** and
   **See what's included**.
4. **Clean up:** everything or chosen chats, with optional Pro filters (sent before or after a date; texts,
   photos & videos, links, voice). Messages from others are shown as "Never touched".
5. **Review:** "You're about to unsend X messages", with the seen/screenshotted and can't-be-undone
   warnings. Nothing destructive happens before **Start cleaning**.
6. **Running:** progress, an ETA based on observed speed, "Keep DeLore open while we clean.", and
   pause, resume and cancel.
7. **Done:** "Fresh start ✨ / X messages cleaned".

## Architecture

```
App/                      SwiftUI app (iOS 17+)
Android/                  Kotlin + Compose app (API 26+)
Packages/DeLoreKit/       Swift core used by iOS
  DeLoreCore/             Domain, engine, Instagram website client, entitlements
  DeLoreFakes/            Test doubles
```

Everything external sits behind a protocol (`MessageSource`, `UnsendService`, `JobStore`,
`SecretStore`, `PurchaseService`, `HTTPTransport`, `EngineClock`, `AnalyticsSink`). An official
integration can replace the current one without touching the UI or the engine.

## Setup

Requirements: macOS with Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate          # creates DeLore.xcodeproj from project.yml
open DeLore.xcodeproj      # scheme "DeLore" (Debug) or "DeLore-Staging"
```

Core tests without Xcode: `swift test --package-path Packages/DeLoreKit`.

Android (JDK 17 + Android SDK):

```bash
cd Android
gradle :app:testDebugUnitTest :app:assembleDebug   # or Android Studio → Open Android/
```

Configurations: **Debug** (verbose redacted logs), **Staging** (release optimisations, for
TestFlight), and **Release** (warnings/errors only). Every configuration uses the live Instagram
integration. Android uses the same live website session in every build.

Configurations: **Debug** (verbose redacted logs), **Staging** (release optimisations, for
TestFlight), and **Release** (warnings/errors only). Every configuration uses the live Instagram
integration.

## Required external configuration

All of it lives in `Config/Base.xcconfig`. No secrets are needed or committed.

| Setting | What to do |
|---|---|
| `DEVELOPMENT_TEAM` | Your Apple team ID (or set it in Xcode) |
| `PRODUCT_BUNDLE_IDENTIFIER` | Your bundle ID (default `app.delore.ios`) |
| `DL_PRIVACY_URL`, `DL_SUPPORT_URL` | Replace the `example.com` placeholders with real pages |
| `DL_TERMS_URL` | Apple's standard EULA by default; replace if you publish your own |
| `DL_PRODUCT_*` | Must match App Store Connect (and `App/StoreKit/DeLore.storekit`) |
| `DL_FREE_LIMIT` | Lifetime free messages (default 100) |

## How authentication works

The user signs in on Instagram's own login page, shown in a `WKWebView` with a non-persistent
data store. DeLore never intercepts the password. After Instagram sets its website session
(`sessionid`, `ds_user_id`, `csrftoken` on instagram.com), those values are stored in the Keychain
via `SessionVault` (`AfterFirstUnlockThisDeviceOnly`). Facebook SSO cookies are not kept.

Discovery and Unsend then call Instagram's website from the phone, using Instagram's published
website client id (`APP_ID` on instagram.com) — not a spoofed iOS/Android app. If Instagram shows
a checkpoint, CAPTCHA, or login challenge, the user completes it on Instagram's page. Cleanup
stops on those signals; it never bypasses them. Disconnect wipes the session with everything else.

The UI never mentions cookies, endpoints, or HTTP. Reconnect is "Reconnect Instagram".

## How the cleanup engine works

1. **Discovery:** `InstagramInboxSync` pages the authenticated inbox (folder `inbox` only, not
   requests) and each thread, and writes a content-free `LocalLibraryStore`. The owner is the
   signed-in `ds_user_id`. A message is kept only when `sentByViewer` or `user_id` matches that
   owner; otherwise it is skipped. Message text is never stored. The export parser remains as a
   tested fallback path, but live cleanup uses website thread/item ids.
2. **Queue:** `QueueBuilder` pages through the source (bounded pages and batches), keeps only
   `author == owner`, applies filters, de-duplicates, skips anything in the cleaned-message ledger,
   and writes items to the store in order.
3. **Authorize:** the job can't start until `authorize()` records the user's confirmation.
4. **Run:** the `CleanupEngine` actor processes items in a deterministic order, persisting
   `processing` *before* each destructive request (it won't send one it couldn't record), and
   persisting the outcome after. Pause and cancel never interrupt an in-flight request. Its result
   is still recorded.
5. **Item states:** `discovered → queued → processing → completed | retryWait | failed | skipped |
   cancelled`. Pausing lives on the job (`running / paused(reason) / completed / cancelled`), so
   50k items aren't rewritten on every pause.
6. **Reconciliation:** anything whose outcome is unknown (timeout after sending, a crash mid-request,
   an unexpected response) is flagged `needsReconcile`. Before any new unsend, the engine does a
   non-destructive presence check: *gone* means completed, *present* means it may retry. Destructive
   calls are never blindly repeated.
7. **Restart:** on launch, `processing` items become `retryWait + needsReconcile`, and a `running`
   job becomes `paused(.interrupted)` with one-tap resume. Journal writes are absolute states, so a
   torn last line or a crash during compaction replays safely.
8. **Ownership, twice:** the builder only queues owner messages, the engine re-checks before every
   request, and a `notOwned` response from the platform skips the item.

## Rate-limit / backoff model (`RatePolicy.conservative`)

| Control | Default |
|---|---|
| Minimum gap between destructive requests | 4 s + 0–2 s jitter |
| Burst cap | 10 per 60 s |
| Hourly cap | 300 per rolling hour |
| Transient-error backoff | 15 s × 2ⁿ, capped at 15 min, jittered 50–100% |
| Rate-limit cool-down | 10 min, doubling to 60 min max, honours `Retry-After` |
| Adaptive slowdown | gaps ×2 per rate limit (max ×8), relaxes after 50 successes |
| Stop after rate limits | 3 in a row, or 6 in one run: pause, "Try again later", respects cool-down |
| Attempts per item | 3, then `failed` |
| Stop after failures | 5 consecutive: pause |
| Session expired / verification | pause immediately; resume only after the user acts |
| Unexpected response | stop safely; reconcile before retrying |

The ETA uses the observed speed (smoothed, including waits) and shows nothing until it has 5
samples. No throughput is ever promised in the UI. The values can be tuned in
`AppConfiguration.ratePolicy` without touching the engine.

## Security & privacy model

- **On device only.** No backend. Nothing from DMs leaves the phone. Analytics are off, with no
  third-party SDK. The `Analytics` abstraction only accepts closed-vocabulary events with bucketed
  sizes, and `Analytics.isSafe` rejects free text and long numbers.
- **Stored locally:** chat titles, and id/timestamp/kind for messages you sent. Never content.
  Files use Data Protection (`completeUntilFirstUserAuthentication`) and are excluded from backups.
- **Secrets:** Keychain only (`ThisDeviceOnly`). `Sensitive<T>` wraps headers and bodies so they
  can't be printed, dumped or interpolated.
- **Logging:** everything goes through `AppLogger`, which runs `Redactor` (cookies, tokens, bearer,
  JWT, emails, long IDs, query strings) and uses `privacy: .private` in `os.Logger`. Release keeps
  warnings and errors only. CI fails on `print`/`NSLog`.
- **Networking:** ephemeral `URLSession` (no cache, cookies or credential storage), HTTPS only,
  TLS 1.2+ with system validation. No pinning, because pinning a third party's rotating certificates
  is brittle and adds no safety.
- **Erase:** Settings → *Disconnect & delete my data* wipes the Keychain (except purchase records),
  library, jobs, ledger and flags.
- **Privacy manifest:** no tracking, no collected data types, UserDefaults reason `CA92.1`.

## StoreKit setup

- **Free:** 100 messages of cleanup (a lifetime allowance kept in the Keychain,
  charged only for messages actually cleaned).
- **One-time cleanup** (`app.delore.cleanup.single`, consumable): one full cleanup at **$9.99**. Credited once
  per verified transaction ID.
- **Pro monthly** (`app.delore.pro.monthly`): **$19.99**/month after the free 100. Unlimited cleanup and filters.
- **Pro yearly** (`app.delore.pro.yearly`): **$59.99**/year (~$5/month). Same Pro group.
- Transactions are verified with `VerificationResult` and finished only after delivery. The app
  listens to `Transaction.updates` and handles `Transaction.unfinished`. Restore calls
  `AppStore.sync()`. There's also Manage subscription. If the store is unreachable, the app stays
  usable on the free tier.
- **Local testing:** the schemes use `App/StoreKit/DeLore.storekit`. Consumables can't be restored
  (an Apple rule), so the paywall copy says a pass covers one cleanup.

## Testing

```bash
swift test --package-path Packages/DeLoreKit        # 91 core tests (any OS)
xcodegen generate && xcodebuild test -scheme DeLore \
  -destination 'platform=iOS Simulator,name=iPhone 16'   # app unit tests
```

The core suite runs the real engine against `FakeInstagramService` in virtual time. It covers every
required scenario: only owner messages queued, received messages never touched, duplicates, pause,
resume, cancel, restart, rate-limit backoff, repeated rate limits stopping the job, session expiry,
checkpoints, network retries, no blind destructive repeats, partial completion, logout, log
redaction, analytics safety, 200k-message conversations in bounded memory, progress correctness,
and crash consistency (torn journal lines, compaction crash, storage failures). There are also
export parsing, ZIP (on Apple platforms), throttling, networking and entitlement tests. CI
(`.github/workflows/ci.yml`) runs all of it plus an unsigned Release build and a secrets and
logging scan.

## Known platform limitations

- Instagram can still present checkpoints, CAPTCHAs, or sign the user out. DeLore stops and asks
  the user to finish that on Instagram; it does not bypass those controls.
- The same category of app exists on the App Store today, but that is **not** a guarantee this
  binary will pass App Review. Login is implemented transparently (Instagram's page in-app).
- Message requests aren't included (only `inbox`). Group-chat titles use Instagram's thread title.
- iOS doesn't allow long-running background work for this, so cleaning only runs while the app is
  open. On backgrounding, the in-flight request finishes and the job pauses. It resumes when the
  app returns.
- Ownership is never guessed. If authorship isn't clear, the message is skipped.

## Remaining manual steps before App Store submission

1. Set `DEVELOPMENT_TEAM` and the bundle ID. Register the app in App Store Connect.
2. Create the three IAP products and the subscription group with these IDs, then add pricing,
   localizations and review screenshots.
3. Host the privacy policy and support pages, and replace the `example.com` URLs. The policy must
   disclose on-device Instagram session storage (as UnSendAll's policy does).
4. Fill in the App Privacy "nutrition label": *Data Not Collected* by DeLore. Instagram receives
   the same traffic the user would generate by unsending in a browser.
5. Archive with the Release scheme, upload, and test purchases in Sandbox/TestFlight (Staging).
6. Optional: localize `Localizable.xcstrings` (it's populated from source at build time).

## Remaining manual steps before Play Store submission

1. Open `Android/` in Android Studio, set a real `applicationId` if you don't want `app.delore.android`.
2. Create the same three products in Play Console (`app.delore.cleanup.single`, `app.delore.pro.monthly`, `app.delore.pro.yearly`) at $9.99 / $19.99 / $59.99.
3. Host privacy/support pages (same as iOS) and replace the `example.com` URLs in `Android/app/build.gradle.kts`.
4. Data safety form: data not collected by DeLore. Instagram receives the same website traffic as unsending in Chrome.
5. Upload an AAB from `assembleRelease`, complete content rating, and test license testers.

Branding: DeLore isn't affiliated with Instagram or Meta. "Instagram" is only used descriptively,
and the icon is an original mark.
