# Retract

**Take it back.** A Gen-Z app for retracting the Instagram DMs *you* sent, in bulk, slowly. iOS and Android clients live in this repo and follow the same product: Instagram-hosted login, on-device session, local unsend. Use is at the user's own risk.

> Instagram has no official consumer DM-unsend API. Retract still performs the core action the same
> way a live App Store competitor (UnSendAll) describes for iOS: the user signs in through
> Instagram's own website, the session stays on the phone, and Unsend runs locally against that
> session. We do **not** collect passwords, spoof a mobile app identity, solve checkpoints, or
> send DMs to a Retract server.
>
> - **Every build:** Instagram-hosted login (WKWebView / Android WebView) → on-device session →
>   inbox discovery → cleanup engine → website Unsend. See [`docs/instagram-unsend.md`](docs/instagram-unsend.md).
>   Launch steps: [`docs/LAUNCH.md`](docs/LAUNCH.md).

## What the app does

1. **Welcome:** "Take it back." / Connect Instagram.
2. **Connect Instagram:** the user signs in on Instagram's own page. We never see the password.
3. **Home:** "Your DMs · 8,923" (the messages *you* sent), plus **Clean up**, **Choose chats** and
   **See what's included**.
4. **Clean up:** everything or chosen chats, with optional Pro filters (sent before or after a date; texts,
   photos & videos, links, voice). Messages from others are shown as "Never touched".
5. **Review:** "You're about to unsend X messages", with the seen/screenshotted and can't-be-undone
   warnings. Nothing destructive happens before **Start cleaning**.
6. **Running:** progress, an ETA based on observed speed, "Keep Retract open while we clean.", and
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

## Required external configuration

All of it lives in `Config/Base.xcconfig`. No secrets are needed or committed.

| Setting | What to do |
|---|---|
| `DEVELOPMENT_TEAM` | Your Apple team ID (or set it in Xcode) |
| `PRODUCT_BUNDLE_IDENTIFIER` | Your bundle ID (default `app.delore.ios`) |
| `DL_PRIVACY_URL`, `DL_TERMS_URL` | Host `docs/legal/*.html` (needed for store consoles). The app shows Privacy/Terms in-app and does not open these in a browser |
| `DL_SUPPORT_URL` | `mailto:contact@kandalintsev.com`. Support in the app opens the FAQ, then this email |
| `DL_PRODUCT_*` | Must match App Store Connect (and `App/StoreKit/DeLore.storekit`) |
| `DL_FREE_LIMIT` | Lifetime free messages (default 100) |

## How authentication works

The user signs in on Instagram's own login page, shown in a `WKWebView` with a non-persistent
data store. Retract never intercepts the password. After Instagram sets its website session
(`sessionid`, `ds_user_id`, `csrftoken` on instagram.com), those values are stored in the Keychain
via `SessionVault` (`AfterFirstUnlockThisDeviceOnly`). Facebook SSO cookies are not kept.

Discovery and Unsend then call Instagram's website from the phone, using Instagram's published
website client id (`APP_ID` on instagram.com) — not a spoofed iOS/Android app. If Instagram shows
a checkpoint, CAPTCHA, or login challenge, the user completes it on Instagram's page. Cleanup
stops on those signals; it never bypasses them. Disconnect wipes the session with everything else.

The UI never mentions cookies, endpoints, or HTTP. Reconnect is "Reconnect Instagram".

## How unsending works

Full write-up: [`docs/instagram-unsend.md`](docs/instagram-unsend.md). Short version:

1. Inbox and threads are read with Instagram’s website session (WebView `fetch` on Android and
   iOS; URLSession/OkHttp alone is often dropped by Instagram’s edge).
2. Unsend uses GraphQL `direct_unsend_message` on `www.instagram.com` only (Relay-only headers
   and a real `fb_dtsg` / mid.`$…`). Numeric REST delete returns 1404006 and is not used.
3. A message is marked unsent only when Instagram confirms it. Unexpected replies fail that
   item and the job continues. Session, checkpoint, and rate-limit still pause.

Desktop Chrome user-agent only. No Instagram-app spoofing. No checkpoint bypass.

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
| Unexpected response | fail that item and continue; session / checkpoint / rate-limit still pause |

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
- **Pro monthly** (`app.delore.pro.monthly`): **$19.99**/month after the free 100. Unlimited cleanup and filters.
- **Pro yearly** (`app.delore.pro.yearly`): **$59.99**/year (~$5/month). Same Pro group.
- `app.delore.cleanup.single` remains a leftover StoreKit ID and is not sold in the paywall.
- Transactions are verified with `VerificationResult` and finished only after delivery. The app
  listens to `Transaction.updates` and handles `Transaction.unfinished`. Restore calls
  `AppStore.sync()`. There's also Manage subscription. If the store is unreachable, the app stays
  usable on the free tier.
- **Local testing:** the schemes use `App/StoreKit/DeLore.storekit`.

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

- Instagram can still present checkpoints, CAPTCHAs, or sign the user out. Retract stops and asks
  the user to finish that on Instagram; it does not bypass those controls.
- The same category of app exists on the App Store today, but that is **not** a guarantee this
  binary will pass App Review. Login is implemented transparently (Instagram's page in-app).
- Message requests aren't included (only `inbox`). Group-chat titles use Instagram's thread title.
- iOS doesn't allow long-running background work for this, so cleaning only runs while the app is
  open. On backgrounding, the in-flight request finishes and the job pauses. It resumes when the
  app returns.
- Ownership is never guessed. If authorship isn't clear, the message is skipped.

## Remaining manual steps before App Store submission

See [`docs/LAUNCH.md`](docs/LAUNCH.md) for store copy, IAP IDs, and review notes.

1. Set `DEVELOPMENT_TEAM` and confirm the bundle ID. Register the app in App Store Connect.
2. Create the subscription group and products (`app.delore.pro.monthly`, `app.delore.pro.yearly`).
   Do not submit `app.delore.cleanup.single`. Add pricing, localizations and review screenshots.
3. Host `docs/legal/privacy.html` and `terms.html` on https://kandalintsev.com/retract/ so App Store
   Connect / Play have public legal URLs (in-app copy alone is not enough for the console). Support
   email: contact@kandalintsev.com.
4. Fill in the App Privacy "nutrition label": declare Instagram username (+ promo on purchase) for
   App Functionality — emailed to the publisher. Do **not** claim Data Not Collected. Chat text is
   not collected. Instagram receives the same traffic as unsending in a browser.
5. Archive with the Release scheme, upload, and test purchases in Sandbox/TestFlight (Staging).
6. Optional: localize `Localizable.xcstrings` (it's populated from source at build time).

## Remaining manual steps before Play Store submission

1. Open `Android/` in Android Studio. Keep `applicationId` `app.delore.android` unless you are
   ready to migrate.
2. Create `app.delore.pro.monthly` and `app.delore.pro.yearly` in Play Console at $19.99 / $59.99.
3. Host the same privacy + terms HTML and paste the URLs in Play Console. Support email:
   contact@kandalintsev.com. The app FAQ and Terms are also in-app.
4. Data safety form: declare username (+ promo) as above — not “Data not collected.” Instagram
   receives the same website traffic as unsending in Chrome.
5. Upload an AAB from `assembleRelease`, complete content rating, and test license testers.

Branding: Retract isn't affiliated with Instagram or Meta. "Instagram" is only used descriptively,
and the icon is an original mark.
