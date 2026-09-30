# How Retract unsends Instagram DMs

Retract never talks to a Retract server and never spoofs an Instagram mobile app.
Login, discovery, and Unsend all happen on the phone against Instagram’s website
session — the same session the user just created on Instagram’s own sign-in page.

This is the path that works in production (confirmed on live accounts). Do not
“simplify” it without re-testing Unsend end-to-end.

## Surfaces

| Host | Used for |
|---|---|
| `www.instagram.com` | Login WebView, inbox/thread GET, GraphQL Unsend, `fb_dtsg` harvest |
| `i.instagram.com` | REST Unsend only, after the hidden WebView navigates here so `fetch` is same-origin |

User-Agent is **desktop Chrome**. Never an Instagram iOS/Android app UA.

## Login and session

1. The user signs in on Instagram’s page in an in-app WebView.
2. Retract copies `sessionid`, `ds_user_id`, and `csrftoken` cookies for `instagram.com`
   into on-device storage (iOS Keychain / Android EncryptedSharedPreferences).
3. The password is never read. Checkpoints and 2FA stay on Instagram’s page.

## Why a WebView `fetch`, not OkHttp / URLSession alone

Instagram’s edge often hangs or drops the app HTTP stack even when Chromium in the
same process can load the site. Inbox and Unsend therefore run `fetch()` inside the
already-authenticated WebView (`InstagramWebViewGateway` on Android; the iOS client
uses the website session the same way).

## Finding messages

- Inbox listing: `GET /api/v1/direct_v2/inbox/` (folder `inbox` only — not requests).
- Thread pages: `GET /api/v1/direct_v2/threads/{id}/`.
- Oversized numeric `item_id` / `user_id` values are quoted before JSON parse so they
  are not rounded.
- Only the signed-in user is queued (`is_sent_by_viewer` or `user_id == ds_user_id`).
- Message **text is never stored**. We keep id, timestamp, and kind.

## Kind tracking (texts vs photos)

Instagram’s `item_type` is frequently missing, set to `"text"` on media, or a newer
`xma_*` share name. Retract classifies from the payload, in this order:

1. Voice (`voice_media` / audio)
2. Shares and links (`media_share`, `generic_xma`, `xma_*`, `link`, …)
3. Photos and videos you sent (`media`, `raven_media`, `clip`, …)
4. Texts (`text`, likes)
5. Everything else (stickers, placeholders, system events)

Shared posts count as **Links & shared posts**, not photos. See
`InstagramItemKind` (Android and iOS).

## Unsend, in order

For each queued item:

1. **GraphQL** `POST https://www.instagram.com/api/graphql`  
   Friendly name `direct_unsend_message`, `doc_id` `26948700068153789`.  
   Variables: `{ "message_id": "mid.$…", "send_data": { "thread_id": "…" } }`.  
   Body includes `fb_dtsg` (from `require('DTSGInitialData')` on www), `lsd`, `av` /
   `__user` from `CurrentUserInitialData`.  
   **Relay-only headers:** `X-CSRFToken`, `X-IG-App-ID`, `X-FB-Friendly-Name`,
   `X-FB-LSD`.  
   Do **not** send `X-Requested-With`, `ig-u-ds-user-id`, or `X-IG-WWW-Claim` on this
   POST — Meta’s ajax layer then returns `error: 1357001` “Log in to continue”
   even with a real `fb_dtsg`. Do not send `__a=1`.

2. **REST fallback** empty-body `POST`
   `https://i.instagram.com/api/v1/direct_v2/threads/{thread}/items/{item}/delete/`  
   The WebView must already be on `i.instagram.com` (same-origin).  
   www.instagram.com has no such route (404 HTML SPA that *looks* logged-out).  
   Fetch from www → i.instagram.com is CORS `Failed to fetch`.  
   A form body with `_uid` / `_uuid` returns JSON `4415001`
   “Prompt has contribution”. Empty body is required.

Success is **honest**: GraphQL `data.direct_unsend_message === true`, or REST JSON
`status` ok/success, or the item is already gone. A `for (;;);` envelope or a
generic HTML 404 is **not** counted as unsent.

## Engine behavior

- Session expired, checkpoint, and rate-limit **pause** the job.
- A single unexpected Instagram response **fails that item and continues**.
  The whole run is not aborted.
- Pacing is `RatePolicy.conservative` (gaps, hourly cap, backoff). Keep the app open.

## What we will not do

- Collect or log passwords
- Spoof Instagram’s mobile app identity
- Bypass checkpoints, CAPTCHAs, or 2FA
- Host DMs on a Retract server
- Blindly repeat a destructive request whose outcome is unknown
