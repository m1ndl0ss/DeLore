# DeLore

**Delete the lore.** A Gen-Z iOS app for cleaning up the Instagram DMs *you* sent, in bulk, slowly and safely.

> **Status: read this first.** Instagram has no official API that lets an app unsend a personal
> account's DMs. Every unofficial route means impersonating Instagram's own apps (private
> endpoints, client IDs, device signatures), which this project refuses to ship. So:
>
> - **Works end to end today:** onboarding, importing Instagram's official data download, on-device
>   discovery of the messages you sent, chat selection, filters, the confirmation step, the full
>   cleanup engine (pacing, backoff, persistence, reconciliation), paywall/StoreKit 2, privacy
>   controls, and erasing your data.
> - **Not live in Release:** the actual unsend call. It sits behind one interface
>   (`App/Sources/Integration/LiveIntegration.swift`). Release builds say plainly that unsending
>   isn't available yet. Debug/Staging builds include a sample-data mode where the whole flow runs
>   against a deterministic fake Instagram.

## What the app does

1. **Welcome:** "Delete the lore." / "Get started".
2. **Connect Instagram:** the user requests their DMs through Instagram's official *Download your
   information* page (JSON format), then picks the `.zip` (or the unzipped folder) in Files. We
   never see a password.
3. **Home:** "Your DMs · 8,923" (the messages *you* sent), plus **Clean up**, **Choose chats** and
   **See what's included**.
4. **Clean up:** everything or chosen chats, with optional Pro filters (sent before a date; texts,
   photos & videos, links, voice). Messages from others are shown as "Never touched".
5. **Review:** "You're about to unsend X messages", with the seen/screenshotted and can't-be-undone
   warnings. Nothing destructive happens before **Start cleaning**.
6. **Running:** progress, an ETA based on observed speed, "Keep the app open while cleaning", and
   pause, resume and cancel.
7. **Done:** "Fresh start ✨ / X messages cleaned".

## Architecture

```
App/                      SwiftUI app (iOS 17+)
  Sources/UI/             Views + design system (Theme, Components)
  Sources/Presentation/   @Observable models: AppModel, ImportModel, CleanupSetupModel, CleanupSessionModel
  Sources/Composition/    AppEnvironment: the composition root
  Sources/Purchases/      StoreKit 2 service, entitlement manager, mock (Debug only)
  Sources/Integration/    LiveIntegration: the single plug-in point for a real unsend integration
  Sources/Configuration/  AppConfiguration (reads Config/*.xcconfig via Info.plist)
Packages/DeLoreKit/       Platform-independent core (compiles and tests on macOS, Linux, Windows)
  DeLoreCore/
    Domain/               Models, the item state machine, jobs, progress
    Engine/               CleanupEngine (actor), QueueBuilder, Throttler, Backoff, RatePolicy, ETA
    Persistence/          FileJobStore (snapshot + append-only journal), protected file I/O
    Export/               Instagram export parser, ZIP reader, content-free LocalLibraryStore
    Integration/          MessageSource / UnsendService protocols + typed IntegrationError
    Networking/           HTTPClient + URLSessionTransport (typed, cancellable, idempotent-only retries)
    Security/             Keychain SecretStore, SessionVault, Redactor, Sensitive<T>, LocalDataEraser
    Analytics/            Closed-vocabulary events, payload safety check, no-op sink
    Entitlements/         Pure allowance rules (free / one-time / Pro)
  DeLoreFakes/            FakeInstagramService (deterministic, scriptable faults), ManualClock
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

Configurations: **Debug** (sample data, mock purchases available, verbose redacted logs),
**Staging** (release optimisations + sample data, for TestFlight), and **Release** (no sample data,
no test hooks, warnings/errors only).

## Required external configuration

All of it lives in `Config/Base.xcconfig`. No secrets are needed or committed.

| Setting | What to do |
|---|---|
| `DEVELOPMENT_TEAM` | Your Apple team ID (or set it in Xcode) |
| `PRODUCT_BUNDLE_IDENTIFIER` | Your bundle ID (default `app.delore.ios`) |
| `DL_PRIVACY_URL`, `DL_SUPPORT_URL` | Replace the `example.com` placeholders with real pages |
| `DL_TERMS_URL` | Apple's standard EULA by default; replace if you publish your own |
| `DL_PRODUCT_*` | Must match App Store Connect (and `App/StoreKit/DeLore.storekit`) |
| `DL_FREE_LIMIT` | Lifetime free messages (default 50) |

## How authentication works

There's no login. The app never asks for an Instagram password and holds no Instagram session.
The user downloads their own data through Instagram's official Accounts Center and picks the file.
`SessionVault` (Keychain, `AfterFirstUnlockThisDeviceOnly`) is in place for a future official
integration's credential, and logout wipes it along with everything else.

## How the cleanup engine works

1. **Discovery:** `ExportImporter` finds `messages/inbox/*/message_N.json` (current and legacy
   layouts, ZIP or folder). It identifies the owner as the one participant present in every chat,
   or asks "Which one is you?" if that's ambiguous, repairs Instagram's mojibake, and keeps only the
   *owner's* messages as `(id, timestamp, kind)`. Message text is never decoded into a value.
   Chats where ownership is ambiguous (the owner isn't listed, or someone shares their name) are
   excluded.
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

- **Free:** scan and preview, plus 50 messages of cleanup (a lifetime allowance kept in the Keychain,
  charged only for messages actually cleaned).
- **One-time cleanup** (`app.delore.cleanup.single`, consumable): one full cleanup. Credited once
  per verified transaction ID.
- **Pro** (`app.delore.pro.monthly`, `app.delore.pro.yearly`; group "DeLore Pro"): unlimited
  cleanup and filters.
- Transactions are verified with `VerificationResult` and finished only after delivery. The app
  listens to `Transaction.updates` and handles `Transaction.unfinished`. Restore calls
  `AppStore.sync()`. There's also Manage subscription. If the store is unreachable, the app stays
  usable on the free tier.
- **Local testing:** the schemes use `App/StoreKit/DeLore.storekit`. UI tests use
  `MockPurchaseService` (Debug only, `-uitesting` / `-mockPurchases`). Consumables can't be restored
  (an Apple rule), so the paywall copy says a pass covers one cleanup.

## Testing

```bash
swift test --package-path Packages/DeLoreKit        # 75 core tests (any OS)
xcodegen generate && xcodebuild test -scheme DeLore \
  -destination 'platform=iOS Simulator,name=iPhone 16'   # app unit + UI tests
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

- **No official unsend API** for personal Instagram accounts (see the top of this file). This is
  the blocker for shipping cleanup to the public.
- The export is a snapshot. Messages sent afterwards need a newer download. Message requests
  aren't included (only `inbox`).
- iOS doesn't allow long-running background work for this, so cleaning only runs while the app is
  open. On backgrounding, the in-flight request finishes and the job pauses. It resumes when the
  app returns.
- Owner detection relies on display names in the export. Ambiguous chats are left out rather than
  guessed.

## Remaining manual steps before App Store submission

1. **Decide the integration.** Either obtain an officially supported way to unsend messages and
   implement it in `LiveIntegration.makeUnsendService`, or reposition v1 as a scan/insights app.
   As built, App Review would see a cleanup product whose core action is unavailable in Release.
2. Set `DEVELOPMENT_TEAM` and the bundle ID. Register the app in App Store Connect.
3. Create the three IAP products and the subscription group with these IDs, then add pricing,
   localizations and review screenshots.
4. Host the privacy policy and support pages, and replace the `example.com` URLs.
5. Fill in the App Privacy "nutrition label": *Data Not Collected*. This matches the privacy
   manifest while analytics stay off.
6. Archive with the Release scheme, upload, and test purchases in Sandbox/TestFlight (Staging).
7. Optional: localize `Localizable.xcstrings` (it's populated from source at build time).

Branding: DeLore isn't affiliated with Instagram or Meta. "Instagram" is only used descriptively,
and the icon is an original mark.
