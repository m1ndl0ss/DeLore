# retract-review-mail — verification-code relay for Play review

Play reviewers can't open email. This worker receives the Instagram test
account's security emails, extracts the 6-8 digit code, and shows the latest
one on an unguessable page a reviewer can open in any browser:

**https://kandalintsev.com/r/EtMJ0fotbnFzpKmB/code**

- Email handler: parses subject + body (quoted-printable aware), stores
  `{code, receivedAt, subject}` under KV key `review:codes` (last 5), and
  forwards every message to contact@kandalintsev.com.
- Page: latest code in large text, minutes since arrival, auto-refresh 10 s,
  per-IP rate limit (30/min), noindex, no caching.

Deploy: `npx wrangler deploy` (route + KV binding are in wrangler.toml).

## One-time dashboard setup (Email Routing)

kandalintsev.com's mail is hosted at **Zoho** (mx.zoho.eu). Do NOT enable
Email Routing on the root domain — Cloudflare would replace the Zoho MX
records and break contact@. Use a routing subdomain instead:

1. dash.cloudflare.com → kandalintsev.com → **Email → Email Routing**.
   If it offers to enable routing for kandalintsev.com (replacing MX), decline.
2. **Settings → Subdomains → Add subdomain** → enter `relay`.
   Cloudflare adds MX/SPF DNS records for `relay.kandalintsev.com` only.
3. **Destination addresses → Add destination** → `contact@kandalintsev.com`
   → click the verification link that lands in that (Zoho) inbox.
   (Required for the worker's forward to work.)
4. **Routing rules → Create address** → custom address `review` on subdomain
   `relay.kandalintsev.com` → action **Send to a Worker** → `retract-review-mail`.
5. Optional, to also own review@kandalintsev.com: in Zoho Mail admin, add
   `review@kandalintsev.com` as an alias/account with a forward to
   `review@relay.kandalintsev.com`.
6. Set the Instagram test account's (apptesting070124) email to
   `review@relay.kandalintsev.com` and confirm the change.

Test: email any 6-8 digit number to `review@relay.kandalintsev.com`; the page
shows it within seconds and a copy arrives at contact@.
