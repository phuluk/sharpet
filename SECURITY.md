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

## Known limitations

* **The captcha is a speed bump.** It is arithmetic evaluated in the browser and
  its answer is in `assets/app.js`. It deters casual automation and nothing
  more. Put Turnstile or hCaptcha in front of `get_quiz_questions` before this
  sees public traffic.
* **The answer key can still be brute-forced.** `question_translations.options`
  is public (you need it to render a question), and `submit_quiz_answer()` will
  tell any caller — including a guest — the right answer once they have guessed.
  That turns "one SELECT" into roughly 20 000 RPC calls, which is a real cost
  increase but not a wall. Closing it fully means requiring a session for
  grading, which in turn means enabling Supabase anonymous sign-in.
* **Guest play is unauthenticated by design.** Guests are rate-limited only by
  Supabase's platform limits.
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

## Checklist before going live

- [ ] *Authentication → Sign In / Providers → Email*: minimum password length 10,
      require digits + mixed case + symbols
- [ ] Confirm *Authentication → URL Configuration* allows only your real origins
- [ ] Turn e-mail confirmation back on
- [ ] Enable leaked-password protection (same panel; needs the Pro plan)
- [ ] Re-run `db/tests/security_tests.sql` against a copy of production
- [ ] Fill in a real contact address in `privacy.html`
