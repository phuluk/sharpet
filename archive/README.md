# archive/

Nothing in here is deployed or used at runtime. It is kept for provenance.

* **`input_questions/`** — the raw question bank as JSON (5 117 entries, three
  languages each). This is the *source of truth* for the question data:
  `tools/build_seed.py` reads it and regenerates `db/03_seed_questions.sql`.
* **`quiz_sql_parts/`** — an earlier, flat `quiz_questions` table plus its data,
  split into chunks. Superseded by `db/`. It shipped with no row-level security
  at all, which in Supabase means public read *and write*; a policy has since
  been appended to `00_schema.sql` in case anyone ever loads it.

The live schema lives in `db/`. See `db/README.md`.
