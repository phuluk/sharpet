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
         db/04_security.sql db/05_rpc.sql; do
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done
```

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
