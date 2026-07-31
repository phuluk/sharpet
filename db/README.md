# Database

Run these in the Supabase SQL editor **in order**. Every file is idempotent, so
re-running the whole set on an existing project is the supported way to apply an
update — there is no separate migration mechanism.

| # | File | What it does |
|---|------|--------------|
| 01 | `01_schema.sql` | Tables, check constraints, indexes |
| 02 | `02_seed_domains.sql` | The 17 domains and their EN/DE/CS names |
| 03 | `03_seed_questions/*.sql` | 5 075 questions × 3 languages (generated) |
| 04 | `04_security.sql` | RLS policies, column grants, the auth trigger |
| 05 | `05_rpc.sql` | The gameplay API the browser actually calls |
| 06 | `06_hardening.sql` | Turnstile verification, RPC rate limits, Auth Hook functions |
| 07 | `07_admin.sql` | Admin layer: user/question moderation, CSV import, tunable settings, audit log |
| 08 | `08_geo.sql` | Country-of-origin tracking (Cloudflare's `cf-ipcountry` header) for the usage dashboard |
| 09 | `09_region_block.sql` | Guest-only continent block (Asia/Africa/South America by default) + manual IP ban list + fixed guest demo pool |

### Step 03 is split into parts

The Supabase SQL editor rejects anything much over a megabyte, and the full seed
is roughly 2 MB. It is therefore emitted as nine numbered files of ~240 KB plus
a small `99_finalize.sql`. Run them in filename order:
`01.sql` … `09.sql`, then `99_finalize.sql`.

Each part is a self-contained set of upserts, so pasting them one at a time is
safe, re-running one is harmless, and stopping halfway just means fewer
questions rather than a broken database.

If you have `psql` and the connection string from **Project Settings →
Database**, you can skip the clicking entirely:

```bash
for f in db/01_schema.sql db/02_seed_domains.sql db/03_seed_questions/*.sql \
         db/04_security.sql db/05_rpc.sql db/06_hardening.sql db/07_admin.sql \
         db/08_geo.sql db/09_region_block.sql; do
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done
```

`06_hardening.sql` also needs two things `psql` can't do for you — see
"Manual dashboard steps" in `SECURITY.md`: creating the Turnstile secret in
Vault, and wiring the two Auth Hook functions it defines into
**Authentication → Auth Hooks** in the dashboard. Until the Vault secret exists,
`verify_turnstile()` fails closed, so guest quiz starts will be rejected —
expected, not a bug, until that step is done.

`07_admin.sql` bootstraps the first admin by e-mail address (currently
`peter.huluk@gmail.com`, near the top of the file, under "profiles:
is_admin / is_banned") — edit that literal before running it if the admin
account uses a different address. Everyone after the first admin is
promoted from `admin.html` itself.

The seed files are generated — edit the JSON in `archive/input_questions/` and
run `python3 tools/build_seed.py` rather than editing the SQL by hand.

## Security model in one paragraph

The browser holds an anon key, which is public by design. What keeps data safe
is that (a) `questions.correct_index` is revoked at the column level so the
answer key cannot be read, (b) `quiz_sessions`, `quiz_answers` and
`reported_questions` are **read-only** to clients and are written exclusively by
`SECURITY DEFINER` functions that stamp `auth.uid()` themselves, and (c) every
policy scopes rows to the calling user. A client can therefore neither read
another player's history nor invent its own score.

## Tests

```bash
psql -v ON_ERROR_STOP=1 -f db/tests/security_tests.sql
```

Run it against a scratch database that has had 01→05 applied, as a superuser
(the script switches into the `anon` and `authenticated` roles). Any failed
assertion aborts the run. See `tools/run_db_tests.sh` for a throwaway local
Postgres that emulates enough of Supabase to run it offline.

## Applying this to an already-deployed project

Re-running 01 → 05 is safe, but note two behaviour changes:

* `03_seed_questions/99_finalize.sql` deactivates the questions the seed leaves
  out rather than deleting them, so existing `quiz_answers` keep their foreign
  key.
* `04_security.sql` revokes the blanket table grants Supabase hands to `anon`
  and `authenticated`. Anything outside this repo that talked to these tables
  directly will need to go through the RPCs instead.
* `06_hardening.sql` drops and recreates `get_quiz_questions()` with an extra
  trailing parameter (`p_turnstile_token`). Any caller still using the old
  4-argument form will get a "function does not exist" error — that's the
  point, it stops the unguarded version from being callable at all. The
  frontend in this repo already calls the 5-argument form.
* `07_admin.sql` adds `is_admin` / `is_banned` to `profiles`. Both are
  readable by the owner (and, per the existing friends policy, by accepted
  friends — a pre-existing trade-off, not new) but not client-writable at
  any point; the only way to change them is `admin_set_user_admin()` /
  `admin_set_user_active()`, both of which re-check `is_admin()` themselves.
* `08_geo.sql` reads Cloudflare's `cf-ipcountry` request header — present
  because Supabase's own API sits behind Cloudflare — rather than calling
  a third-party geo-IP service. No visitor IP is sent anywhere outside the
  project to get a country. Historical `usage_events` rows from before
  this migration have `country = null` and show up as `"??"` in the admin
  usage tab's by-country breakdown, not as an error.
* `09_region_block.sql` only ever blocks a caller with `auth.uid() is null`
  — an existing registered account is never affected, no matter where it
  connects from. Sign-up itself can't reliably be blocked by geography this
  way (see the note at the top of the file); what's actually enforced is
  that gameplay never works for a blocked-region guest, so registering from
  one doesn't get you anywhere either. It also drops and recreates
  `admin_list_questions()` and `admin_update_question()` with an extra
  `is_guest_demo` column/parameter — same non-negotiable-arity-change
  reasoning as `get_quiz_questions()` in `06_hardening.sql`.
