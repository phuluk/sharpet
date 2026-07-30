# Sharpet — setup

A static site (no build step) talking directly to Supabase. Read
[`SECURITY.md`](SECURITY.md) before changing anything under `db/` or `assets/`.

```
index.html          landing page
app.html            the app shell
privacy.html        privacy notice
assets/
  app.js            app logic          assets/app.css
  landing.js        landing demo       assets/landing.css
  i18n.js           EN / DE / CS strings + the t() helper
  config.js         Supabase project URL and anon key
  fonts/            self-hosted webfonts (generated)
  vendor/           pinned supabase-js
db/                 schema, seed data, RLS, RPC  → db/README.md
tools/              seed + font generators, local DB test runner
archive/            raw source data and the superseded schema
vercel.json         security headers and caching
```

## 1. Create the Supabase project

1. <https://supabase.com> → New project. Save the database password somewhere safe.
2. **SQL Editor → New query**, then run, in order:
   `db/01_schema.sql`, `db/02_seed_domains.sql`, every file in
   `db/03_seed_questions/` by filename (`01.sql` … `09.sql`, then
   `99_finalize.sql`), `db/04_security.sql`, `db/05_rpc.sql`.

   The seed is split because the SQL editor rejects queries much over a
   megabyte. If you have `psql` and the connection string from **Project
   Settings → Database**, `db/README.md` has a one-line loop that does the whole
   thing at once. Every file is idempotent — re-running the set is how you apply
   an update.
3. **Authentication → Sign In / Providers → Email** (not *Database → Policies*,
   which is RLS): confirm the provider is enabled, then in the same panel set
   **Minimum password length** to **10** and require digits, lower- and
   uppercase letters and symbols. The signup form enforces 10 characters, but
   only this setting enforces it server-side.
   Direct link: `/dashboard/project/<ref>/auth/providers?provider=Email`
4. Same panel: **Prevent use of leaked passwords** (HaveIBeenPwned lookup).
   Pro plan and above only — on Free it is not available.

   Existing accounts with shorter passwords can still sign in; they get a
   `WeakPasswordError`, so tightening this later is safe.
5. **Authentication → URL Configuration**: list only your real origins as
   redirect URLs. The password-reset link comes back to `app.html?mode=reset`.
6. **Project Settings → API**: copy the **Project URL** and the **anon public**
   key.

## 2. Point the frontend at it

Edit `assets/config.js`:

```js
window.SHARPET_CONFIG = Object.freeze({
  supabaseUrl: 'https://YOUR-PROJECT.supabase.co',
  supabaseAnonKey: 'YOUR-ANON-KEY'
});
```

The anon key belongs in the browser — it is a publishable identifier, not a
secret. What protects the data is the RLS in `db/04_security.sql`. **Never** put
a `service_role` key here; that one bypasses RLS entirely.

If you change the project URL, update the `connect-src` entry in `vercel.json`
to match, or the CSP will block every request.

## 3. Run it locally

```bash
python3 -m http.server 8000
# → http://localhost:8000/index.html
```

Worth checking end to end:

* play as a guest — answering should work, and nothing should appear in
  `quiz_sessions`
* sign up, play, then look at `quiz_sessions` / `quiz_answers` in the table editor
* report a question while logged in → a row in `reported_questions`
* switch language mid-quiz — the question and options should change language
  without the options moving
* open devtools → Network and confirm no response ever contains `correct_index`

Local `http.server` does not send the `vercel.json` headers, so the CSP is only
live once deployed. Check it with `curl -I https://your-domain/` after deploying.

## 4. Deploy to Vercel

1. Push to GitHub. Framework preset: **Other** — it is a static site.
2. Deploy. `vercel.json` applies the security headers and cache policy.

No environment variables are needed.

## 5. Regenerating the generated files

```bash
# question seed, from archive/input_questions/*.json
python3 tools/build_seed.py

# self-hosted fonts
npm install @fontsource/inter @fontsource/space-grotesk @fontsource/jetbrains-mono
python3 tools/build_fonts.py

# database security tests — spins up a throwaway postgres, applies db/01..05,
# and asserts that anon/authenticated cannot reach what they shouldn't
./tools/run_db_tests.sh

# static frontend checks — dangling data-actions, missing element ids,
# untranslated keys, CSP violations
python3 tools/check_frontend.py

# headless run-through of a real game in jsdom, as guest and signed in
npm install --no-save jsdom
node tools/dom_smoke_test.mjs
```

## 6. Adding a language

1. Add a fourth key (e.g. `fr`) to `window.STRINGS` in `assets/i18n.js` and add
   `'fr'` to the `SUPPORTED` array at the bottom of the same file.
2. Add `'fr'` to every `check (language_code in (...))` in `db/01_schema.sql`,
   and to the three `not in ('en','de','cs')` guards in `db/05_rpc.sql`.
3. Add an `FR` button to the `.lang-options` markup in `index.html`,
   `app.html` and `privacy.html`.
4. Seed `question_translations` and `domain_translations` rows for it.

## 7. What is still a placeholder

* **Admin review of reported questions** — rows land in `reported_questions`,
  but there is no UI. Browse them in the Supabase table editor.
* **Friends / leaderboard** — the `friendships` table and its policies exist and
  are tested, but nothing in the UI creates or shows friendships yet.
* **Captcha** — a client-side arithmetic check. A deterrent, not bot protection.
  See the note in `SECURITY.md`.
* **"View all"** on the dashboard's history and reports cards.
* **Question distribution is lopsided** — 3 047 of the 5 075 questions sit in
  *General Culture/Miscellaneous*, and four domains have exactly two questions.
  That comes from the source data, not the import: picking *Economics* gives you
  a two-question game.
