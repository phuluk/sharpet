# Setting up Sharpet with Supabase + Vercel

## 1. Create the Supabase project
1. Go to https://supabase.com → New project.
2. Pick a name, database password (save it somewhere safe), and region.
3. Once it's created, open **SQL Editor** → **New query**, paste the entire contents of `supabase-schema.sql`, and run it.
   - This creates all tables, seeds the domains and a handful of starter questions, and sets up Row Level Security so users can only see their own quiz history.
4. Go to **Authentication → Providers** and confirm **Email** is enabled (it is by default).
   - Optional: under **Authentication → URL Configuration**, if you don't want users to have to confirm their email before logging in, you can disable "Confirm email" for faster testing. Turn it back on before going live.
5. Go to **Project Settings → API**. You'll need two values:
   - **Project URL**
   - **anon public** key

## 2. Connect the frontend to Supabase
Open `app.html` and find this block near the top of the script:

```js
var SUPABASE_URL = 'YOUR_SUPABASE_PROJECT_URL';
var SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';
```

Replace both with the values from step 1.5. That's the only code change required — everything else (login, questions, scoring, reporting) already talks to Supabase.

## 2b. Language support (EN / DE / CS)
`i18n.js` is a shared file included by both `index.html` and `app.html` — make sure it's uploaded alongside them (same folder). It holds:
- All UI text in English, German, and Czech
- The `t(key)` helper used throughout `app.html` to look up the right string
- The language switcher pills in both pages' nav bars, which save the choice to the visitor's browser (`localStorage`) so it's remembered on their next visit

Questions and domain names are translated too, but that data lives in Supabase (`question_translations` and `domain_translations` tables) rather than in `i18n.js` — the schema already seeds all three languages for the starter questions.

To add a new language later: add a fourth key (e.g. `fr`) to `window.STRINGS` in `i18n.js`, add `'fr'` to the `check (language_code in (...))` constraints and seed rows in `supabase-schema.sql`, and add an `FR` button to the `.lang-switch` markup in both HTML files.

## 3. Test locally before deploying
Since browsers block some things when you just double-click an HTML file (like `fetch` calls in certain setups), serve the folder locally instead:

```bash
cd quizapp
python3 -m http.server 8000
```

Then open `http://localhost:8000/index.html` in your browser. Try:
- Signing up with a real email you can access (Supabase sends a confirmation link by default)
- Logging in and playing a guest-style game while logged in — check the **Supabase Table Editor** afterward to see rows appear in `quiz_sessions` and `quiz_answers`
- Reporting a question — check the `reported_questions` table

## 4. Deploy to Vercel
1. Push this folder to a GitHub repository (or use Vercel's drag-and-drop deploy for static sites). Make sure `index.html`, `app.html`, and `i18n.js` all end up in the same folder — `i18n.js` is loaded by both pages via a relative `<script src="i18n.js">` tag.
2. In Vercel: **Add New → Project → Import** your repo.
3. Framework preset: choose **Other** (it's a static site, no build step needed).
4. Deploy. Vercel will host `index.html` and `app.html` directly.

No environment variables are needed on Vercel since the Supabase URL/key are public-safe values embedded in the frontend (the anon key is designed to be exposed — it's your RLS policies that keep data safe, not secrecy of that key).

## 5. What's still a placeholder / not wired up
- **Admin review of reported questions** — rows land in `reported_questions` but there's no admin UI yet to review/resolve them. For now you can browse them directly in the Supabase Table Editor.
- **Friends / leaderboard** — the `friendships` table and RLS policies exist, but the "Stats" screen still shows mocked friend data, not real queries yet.
- **Per-domain accuracy on the stats screen** — also still mocked; would need a query aggregating `quiz_answers` joined through `quiz_sessions` and `questions.domain_id`.
- **Captcha** — still a simple client-side math check. It's a light deterrent, not a real bot-blocking service; fine for a small internal tool, but swap in something like hCaptcha/Turnstile if this gets public traffic.

Happy to wire up any of these next once you've confirmed the core signup → play → save flow works end to end.
