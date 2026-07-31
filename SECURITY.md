# Security notes

This file records what was wrong, what the fix was, and what is still open. It
is meant to be read before changing anything in `db/` or `assets/`.

## Threat model

Sharpet is a static site talking straight to Postgres through PostgREST. There
is no backend to hide logic in. Every byte of JavaScript and the anon key are
public, so the only things that can actually enforce a rule are:

1. **Row Level Security policies** — who may see which rows.
2. **Column-level `GRANT`s** — which columns exist at all, from the client's view.
3. **`SECURITY DEFINER` functions** — the only code path allowed to write.

Anything enforced solely in `assets/app.js` is a convenience, not a control.

## Admin layer (`db/07_admin.sql`, `admin.html`)

Still no backend: "admin" is a normal Supabase Auth account with
`profiles.is_admin = true`, and every admin action is a `SECURITY DEFINER`
RPC (`admin_*`) that calls `is_admin()` itself before doing anything, and
writes a row to `admin_audit_log`. `admin.html` deciding whether to *show*
the admin UI is a convenience, same as everywhere else in this app — the
actual gate is server-side on every call, so it doesn't matter that
`admin.html` is a public, unauthenticated static file reachable by anyone
who guesses the URL (it's also in `robots.txt` and `noindex`, but that's
obscurity, not a control). A non-admin who loads it just sees "not an
admin" and every RPC call fails closed.

Two things worth knowing before relying on this:

* **"Deactivate" doesn't revoke a session or block login.** It sets
  `profiles.is_banned`, checked inside `get_quiz_questions`,
  `submit_quiz_answer`, `start_quiz_session` and `report_question`. A
  deactivated user can still log in and see their own past history; they
  just can't start a quiz, submit an answer, or file a report. A real
  account lock (revoke sessions, block login outright) needs the Supabase
  Auth Admin API, which needs the `service_role` key — deliberately kept
  out of the browser. If you need that later, it has to go through a
  server or Edge Function, not this admin page.
* **The first admin is bootstrapped by e-mail**, not through the UI (there's
  no admin yet to click the button). `07_admin.sql` sets
  `peter.huluk@gmail.com` as admin on every run — after that, promote or
  demote other accounts from Users → Make admin / Remove admin. An admin
  cannot remove their own admin flag (guards against locking everyone out);
  have a second admin do it.

The usage dashboard's by-country breakdown (`db/08_geo.sql`) reads
Cloudflare's `cf-ipcountry` request header — a header PostgREST already
receives because Supabase's API sits behind Cloudflare — rather than
calling a third-party geo-IP lookup. No visitor IP leaves the project to
produce it.

The CSV question-import path (`admin_upsert_questions_csv`) re-validates
everything server-side regardless of what the browser's own CSV parser
already checked — same "client-side is a convenience" rule. Matching for
created/updated/duplicate is by normalized English question text, since
that's the only stable, human-meaningful key a CSV of new questions has; a
row that fails validation is skipped and reported, never allowed to abort
the rest of the batch.

## Region blocking and the guest demo pool (`db/09_region_block.sql`)

Two separate rules, both guest-only (`auth.uid() is null`) — an existing
registered account is never affected by either, regardless of where it
connects from:

* **Continent block.** `client_country()` reads Cloudflare's `cf-ipcountry`
  header (same source as the usage dashboard's by-country numbers) and
  `is_region_blocked()` checks it against `private.country_continent` and
  the `blocked_continents` setting (default `Asia,Africa,South America`,
  editable in Admin → Region blocking). A request with no resolvable
  country **fails open** — this blocks specific regions, it isn't meant to
  lock out every guest the one time Cloudflare's header is missing.
* **Manual IP/CIDR bans**, independent of the continent rule, managed from
  the same admin tab — for a specific troublesome visitor rather than an
  entire region.

Both are enforced inside `get_quiz_questions()` and `submit_quiz_answer()`
directly, so they apply the same whether the frontend calls them or not.
`assets/app.js` also greys out the Play/Log in buttons and calls
`region_status()` up front — that part is the same "convenience, not a
control" as everywhere else: it's there so a blocked visitor sees a clear
message instead of a confusing failure after clicking, not to do the actual
blocking.

**Sign-up itself can't be blocked the same way.** The `before-user-created`
Auth Hook runs over a different connection than PostgREST requests and
never sees `cf-ipcountry` — only a raw IP (`event.metadata.ip_address`,
already used by `hook_restrict_signup_by_ip`). Resolving a country from a
raw IP without calling a third-party geo-IP service (which would mean
sending every signup's IP off this project) needs a full local
IP-range-to-country database such as MaxMind GeoLite2, which isn't wired up
here. In practice this doesn't leave much of a gap: a blocked-region
visitor can still create an account, but that account can never play a
quiz, guest or logged in, because the block is enforced on every gameplay
call regardless of auth state for a brand-new session with nothing else
going for it. If literal sign-up blocking by geography becomes a hard
requirement later, importing GeoLite2 into `private.country_continent`-style
tables keyed by CIDR range (rather than a header) is the way to get there.

**Guest demo pool.** Unregistered players only ever draw from questions
flagged `questions.is_guest_demo` — at least 10 per domain, topped up by
`09_region_block.sql` (safe to re-run after reseeding: it only adds rows for
a domain still short of 10, never removes any), and adjustable afterwards
from the question editor's "In the guest demo pool" checkbox. A registered
account still sees the full active question bank. This closes the
"brute-force the whole 5 000-question answer key as a guest" scenario
`06_hardening.sql`'s rate limit only slowed down before — a guest's
answer-key exposure is now capped at the demo pool's size, permanently, not
just rate-limited.

## Fixed

| Issue | Was | Now |
|---|---|---|
| **Answer key was public** | `questions.correct_index` was readable by `anon`; the whole 5 000-question answer key was one `SELECT` away | Column revoked at the grant level. Questions are served by `get_quiz_questions()`, which returns options with no index. `submit_quiz_answer()` grades on the server and only then reveals the answer |
| **Clients wrote their own scores** | `quiz_answers.is_correct` and `quiz_sessions.correct_count` were client-supplied through an `for all` RLS policy | Both tables are read-only to clients. `submit_quiz_answer()` computes correctness; `finish_quiz_session()` recomputes the totals from the stored rows |
| **Every profile was world-readable** | `create policy ... for select using (true)` on `profiles`. Display names default to the local part of the e-mail, so this leaked partial addresses of every user to any anonymous visitor | Readable by the owner and by accepted friends only |
| **Reports could be forged and spammed** | `reported_questions` had `for insert with check (true)`: anyone could file unlimited reports under any `user_id`, and set `resolved` | Insert revoked. `report_question()` stamps `auth.uid()`, requires a login, caps the reason at 500 chars, rate-limits to 20/hour and ignores duplicate open reports |
| **`update` policies with no `with check`** | A user could `update` their `profiles` row and change `id` to someone else's; the recipient of a friend request could rewrite `user_id`/`friend_id` | `with check` added on both; column grants narrowed so `id` is not updatable at all |
| **`SECURITY DEFINER` without a pinned `search_path`** | `handle_new_user()` was a textbook search-path hijack target | `set search_path = ''` plus fully-qualified names, on every definer function |
| **Unvalidated user metadata** | `raw_user_meta_data->>'display_name'` went straight into `profiles` | Control characters stripped, capped at 32 chars, plus a DB check constraint |
| **Account enumeration** | Supabase auth errors were rendered verbatim, so "User already registered" told an attacker which e-mails exist | Errors are mapped to generic messages; the reset form already returned a constant response |
| **No security headers** | None | `vercel.json` sets CSP, HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, COOP, CORP and `Permissions-Policy` |
| **Third-party script with a floating version** | `cdn.jsdelivr.net/.../supabase-js@2` — an unpinned, unverified supply-chain dependency | Vendored at `assets/vendor/supabase-js-2.111.0.js` and served from the same origin. CSP is `script-src 'self'` |
| **Google Fonts** | Every visitor's IP was sent to Google | Self-hosted in `assets/fonts/`; `font-src 'self'` |
| **XSS surface** | Dashboard rows were assembled with `innerHTML` + a hand-rolled `escapeHtml` | All rendering uses `createElement` / `textContent`; there is no HTML string building left |
| **No table constraints** | Negative counts, out-of-range indexes, unbounded text | Check constraints on languages, counts, indexes, colours, reason length |
| **Same question answerable repeatedly** | A session could hold many rows for one question | Unique index on `(session_id, question_id)` |
| **Captcha was a client-side speed bump** | Arithmetic evaluated in the browser, answer shipped in `assets/app.js` — deterred nothing but the laziest script | Replaced with Cloudflare Turnstile. The token is verified *inside Postgres* (`verify_turnstile()` in `db/06_hardening.sql`, calling Cloudflare's `siteverify` via the `http` extension) before `get_quiz_questions()` returns anything to a guest. A logged-in caller skips the widget entirely — they're already accountable via rate limits on their account |
| **`get_quiz_questions()` / `submit_quiz_answer()` had no rate limit** | A guest could call either an unlimited number of times — the "≈20 000 RPC calls to brute-force the answer key" path this file used to flag as open | Both now go through `check_rate_limit()`: 10 quiz-starts / 10 min and 200 gradings / 10 min, keyed by account when logged in or by IP (`client_ip()`, read from PostgREST's forwarded `X-Forwarded-For`) for guests |
| **No throttle on repeated signups from one IP** | Only Supabase's built-in, email-quota-tied rate limit applied | `before-user-created` Auth Hook (`hook_restrict_signup_by_ip`) caps new accounts at 5 per IP per 24h, independent of the email-sending quota. Must be wired in the dashboard — see below |
| **No throttle on repeated failed logins against one account** | Supabase's built-in login rate limit is per-IP only, so spreading guesses across IPs bypassed it | `password-verification-attempt` Auth Hook (`hook_password_verification_attempt`) enforces a 3-second minimum between failed attempts *per account*, regardless of source IP. Must also be wired in the dashboard |

## Known limitations

* **Guest play is still unauthenticated by design.** Turnstile plus the new
  rate limits make scraping and brute-forcing expensive, not impossible — a
  determined, well-resourced attacker with many IPs and solved captchas could
  still grind through the question bank slowly. There is no backend here to
  add a harder wall without giving up the "no server to operate" architecture.
* **IP-based checks are best-effort.** `client_ip()` trusts the
  `X-Forwarded-For` header PostgREST is handed. That's set by Supabase's own
  edge and is reliable for this deployment (the browser talks to Supabase
  directly, nothing of ours sits in between to spoof it), but it is still a
  single data point — VPNs, CGNAT and mobile carriers put many real users
  behind one IP and one attacker behind many.
* **No admin UI for reported questions.** Rows land in `reported_questions`;
  review them in the Supabase table editor.
* **Password rules are enforced client-side only.** The sign-up and reset forms
  require 10 characters, mixed case, a digit and a symbol, shown as a live
  checklist. Set the *same* rules under *Authentication → Sign In / Providers →
  Email* — otherwise a crafted request bypasses the form entirely. The two must
  stay in step: `SYMBOLS` / `passwordRules()` in `assets/app.js` and
  `pw_rule_*` in `assets/i18n.js` describe the client half.
* **Leaked-password protection needs a paid plan.** The HaveIBeenPwned check
  lives in the same panel but is Pro-and-above only, so on the Free plan this
  particular control is simply unavailable.
* **`friendships` has no reciprocal-row cleanup**, and the friends UI is not
  built yet — the policies are in place ahead of the feature.
* **Auth tokens sit in `localStorage`** (Supabase's default for a pure
  client-side app with no backend to set an httpOnly cookie). The strict CSP
  (`script-src` with no `unsafe-inline`, no third-party scripts besides the
  vendored Supabase client and Turnstile) is what keeps this from being an
  easy XSS-to-token-theft path — there's no further hardening available
  without adding a server.

## Manual dashboard steps (not reachable from SQL or this repo)

Supabase and Cloudflare configuration that has to be clicked through by hand.
Nothing in `db/06_hardening.sql` takes effect end-to-end until these are done.

- [ ] Create a Cloudflare Turnstile widget (dash.cloudflare.com → Turnstile).
      Add your real domain(s); for local testing add `localhost` per
      [Cloudflare's testing docs](https://developers.cloudflare.com/turnstile/reference/testing/)
- [ ] Paste the Turnstile **Site key** into `assets/config.js` →
      `turnstileSiteKey` (replacing the `REPLACE_WITH_...` placeholder)
- [ ] In the Supabase SQL editor, store the Turnstile **Secret key** in Vault:
      `select vault.create_secret('<secret-key>', 'turnstile_secret_key');`
      — until this exists, `verify_turnstile()` fails closed and guest quiz
      starts will be rejected (expected, not a bug)
- [ ] *Authentication → Auth Hooks → Before User Created* → Postgres function →
      `public.hook_restrict_signup_by_ip`
- [ ] ~~*Authentication → Auth Hooks → Password Verification Attempt*~~ —
      **requires the Team plan or above**; not available on Free or Pro. The
      `public.hook_password_verification_attempt` function is created and
      ready regardless, but sits unused until wired up. Not critical in the
      meantime: Supabase's own IP-based rate limit on `/auth/v1/token`
      (plan-independent, ~1800 req/hour with burst protection) still covers
      the bulk of login brute-forcing; what's missing is only the narrower
      per-account throttle across many IPs. Revisit if you ever upgrade.
- [ ] *Authentication → Bot and Abuse Protection → Enable CAPTCHA protection*:
      provider Cloudflare Turnstile, paste the same Secret key. This is what
      makes Supabase Auth itself (sign up / log in / password reset) honour
      the `captchaToken` the frontend now sends
- [ ] *Authentication → Rate Limits*: review and tighten the defaults —
      in particular `rate_limit_otp` (password-reset / magic-link emails) and
      the anonymous-sign-in limit if you enable that feature later
- [ ] *Authentication → Sign In / Providers → Email*: minimum password length 10,
      require digits + mixed case + symbols
- [ ] Confirm *Authentication → URL Configuration* allows only your real origins
- [ ] Turn e-mail confirmation back on
- [ ] Enable leaked-password protection (same panel; needs the Pro plan)
- [ ] Re-run `db/tests/security_tests.sql` against a copy of production
- [ ] Fill in a real contact address in `privacy.html`
- [ ] Confirm the bootstrap e-mail in `07_admin.sql` (section 0) is the
      account that should become the first admin before running it — no
      dashboard step needed otherwise, the admin layer is pure SQL
