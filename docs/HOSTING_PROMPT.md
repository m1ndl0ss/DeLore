# Claude Code prompt — host Retract static files on kandalintsev.com

Copy everything below the line into Claude Code **in the website repo** (the project that deploys `kandalintsev.com`). Do not edit the Retract app for this task.

---

You are updating the live site for **kandalintsev.com** so Retract’s App Store / Play Console URLs return **static documents**, not the SPA shell.

## Goal

These three URLs must return the **exact file bodies** (correct `Content-Type`), not `index.html` from the React/Vite app:

| Live URL | Source file in the Retract repo | Content-Type |
|---|---|---|
| `https://kandalintsev.com/retract/privacy` | `docs/legal/privacy.html` | `text/html; charset=utf-8` |
| `https://kandalintsev.com/retract/terms` | `docs/legal/terms.html` | `text/html; charset=utf-8` |
| `https://kandalintsev.com/r/7f3a/pc.json` | `docs/r/7f3a/pc.json` | `application/json; charset=utf-8` |

Optional (nice to have, not required for store submit):

| Live URL | Source |
|---|---|
| `https://kandalintsev.com/retract/faq` | `docs/legal/faq.html` |

## Why this is broken today

`GET` on those paths currently returns the marketing SPA (`<!doctype html>…Matvei Kandalintsev…`). Apple/Google need a real privacy policy page. The Retract app also fetches `pc.json` for promo codes and complimentary Pro allowlist — HTML breaks that parse.

## What to do

1. Get the three source files from the Retract repo `m1ndl0ss/DeLore` (paths above). Prefer the current `feature/delore-mvp` / main branch tip. If this website repo already vendors copies, sync them to match Retract’s `docs/legal/*.html` and `docs/r/7f3a/pc.json`.
2. Host them as **static assets** with routes that win over the SPA catch-all:
   - Prefer files like `public/retract/privacy.html` + rewrite `/retract/privacy` → that file (trailing slash optional; both should work or redirect once).
   - Prefer `public/r/7f3a/pc.json` served as JSON with **no** HTML layout wrapper.
3. **Do not** link `pc.json` from the public nav, footer, sitemap, or robots highlights. Obscure path is intentional.
4. **Do not** change Retract product copy, add a Retract marketing landing page, or put promo codes on the public site.
5. Keep CORS simple: same-origin GET is enough. If you set headers, allow GET from any origin for `pc.json` only if needed (`Access-Control-Allow-Origin: *` is OK for this public JSON).
6. Cache: short or revalidate for `pc.json` (codes change without app updates). Legal pages can be longer-lived.
7. After deploy, **verify with curl** (fail if body starts with the SPA title or contains `/assets/index-`):

```bash
curl -sSI https://kandalintsev.com/retract/privacy | head
curl -s https://kandalintsev.com/retract/privacy | head -n 5
# Expect: <!DOCTYPE html> … <title>Retract — Privacy</title>

curl -sSI https://kandalintsev.com/retract/terms | head
curl -s https://kandalintsev.com/retract/terms | head -n 5
# Expect: title Retract — Terms of use

curl -sSI https://kandalintsev.com/r/7f3a/pc.json | head
curl -s https://kandalintsev.com/r/7f3a/pc.json
# Expect raw JSON like:
# {"percentOff":10,"codes":["RETRACT10","REF10"],"complimentaryUsernames":[…]}
```

8. Report back: final deploy URL/commit, and paste the three curl body snippets proving they are not the SPA.

## Constraints

- Ask Matvey before any destructive change to unrelated site pages.
- Do not commit secrets.
- Do not list promo codes or complimentary usernames on any public marketing page.
- Trailing-slash behavior: pick one canonical URL per page; 301 the other if both exist.

## Done when

- Privacy and terms show Retract legal copy in a browser with JS disabled.
- `pc.json` parses as JSON in `JSON.parse`.
- Store console can use the privacy URL as the public Privacy Policy link.
