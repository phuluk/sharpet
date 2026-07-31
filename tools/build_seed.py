#!/usr/bin/env python3
"""Build db/03_seed_questions.sql from the raw question JSON in archive/input_questions/.

Why this exists
---------------
The previously committed seed only contained the first of the two source files
(2558 of 5117 questions) and stored the correct answer at index 0 or 1 for
every single question. This script regenerates the seed from both sources and:

  * drops duplicate questions (matched on the English text),
  * drops distractors that collide with the correct answer or with another
    distractor **in any of the three languages** — a collision in one language
    would otherwise produce two identical options in that language,
  * shuffles the options with a fixed seed, so the correct answer is spread
    evenly across all positions and the output is reproducible,
  * keeps the option order identical across en/de/cs, which is what lets a
    single questions.correct_index describe all three translations.

Usage:  python3 tools/build_seed.py
"""

from __future__ import annotations

import json
import random
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "archive" / "input_questions" / "quiz_questions_part1.json",
    ROOT / "archive" / "input_questions" / "quiz_questions_part2.json",
    ROOT / "archive" / "input_questions" / "quiz_questions_part3.json",
]
OUT_DIR = ROOT / "db" / "03_seed_questions"

# The Supabase SQL editor rejects anything much over a megabyte, so the seed is
# emitted as a numbered series of files small enough to paste one at a time.
MAX_FILE_BYTES = 250_000

LANGS = ("en", "de", "cs")
MIN_OPTIONS = 4          # the UI offers up to 4 answers per question
BATCH = 250              # questions per INSERT statement
SEED = 20260729

HEADER = """\
-- ============================================================
-- Sharpet — question seed, part {part} of {total}
-- GENERATED FILE — do not edit by hand.
-- Regenerate with:  python3 tools/build_seed.py
--
-- Run every file in this directory in numerical order. Each one is a
-- self-contained set of upserts, so the Supabase SQL editor can take them
-- one at a time, and re-running any of them is harmless.
-- ============================================================

"""

FINALIZE_HEADER = """\
-- ============================================================
-- Sharpet — question seed, finalize
-- GENERATED FILE — do not edit by hand.
--
-- Run this LAST, after every numbered part.
-- ============================================================

"""


def sql_str(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def norm(value: str) -> str:
    return " ".join(value.split()).casefold()


def load_questions() -> list[dict]:
    rows: list[dict] = []
    for path in SOURCES:
        if not path.exists():
            sys.exit(f"missing source file: {path}")
        rows.extend(json.loads(path.read_text(encoding="utf-8")))
    return rows


def build() -> None:
    rng = random.Random(SEED)
    raw = load_questions()

    domain_ids: dict[str, int] = {}
    seen_text: set[str] = set()
    prepared: list[dict] = []
    dropped: list[int] = []
    skipped = Counter()

    for q in sorted(raw, key=lambda r: r["id"]):
        text = q["question"]
        answer = q["correct_answer"]

        if not all(text.get(l, "").strip() and answer.get(l, "").strip() for l in LANGS):
            skipped["incomplete translation"] += 1
            dropped.append(q["id"])
            continue

        key = norm(text["en"])
        if key in seen_text:
            skipped["duplicate question"] += 1
            dropped.append(q["id"])
            continue
        seen_text.add(key)

        # Keep a distractor only if it is distinct from the correct answer and
        # from every already-kept distractor in *all* languages.
        taken = {norm(answer[l]) for l in LANGS}
        distractors: list[dict] = []
        for d in q["distractors"]:
            if not all(d.get(l, "").strip() for l in LANGS):
                continue
            keys = {norm(d[l]) for l in LANGS}
            if keys & taken:
                continue
            taken |= keys
            distractors.append(d)

        if len(distractors) < MIN_OPTIONS - 1:
            skipped["too few usable distractors"] += 1
            dropped.append(q["id"])
            continue

        options = [answer] + distractors
        order = list(range(len(options)))
        rng.shuffle(order)
        options = [options[i] for i in order]
        correct_index = order.index(0)

        domain = q["domain"]
        if domain not in domain_ids:
            domain_ids[domain] = len(domain_ids) + 1

        prepared.append(
            {
                # Keep the source id: rows already in the database point at it
                # from quiz_answers, so renumbering would silently reassign
                # historical answers to different questions.
                "id": q["id"],
                "domain_id": domain_ids[domain],
                "correct_index": correct_index,
                "difficulty": q.get("difficulty") or "medium",
                "text": text,
                "options": options,
            }
        )

    # The domain ids must line up with 02_seed_domains.sql, which is keyed on
    # the English domain name. Reuse that mapping rather than inventing one.
    domain_map = parse_domain_ids()
    unknown = sorted(set(domain_ids) - set(domain_map))
    if unknown:
        sys.exit(f"domains missing from 02_seed_domains.sql: {unknown}")
    for row in prepared:
        name = next(n for n, i in domain_ids.items() if i == row["domain_id"])
        row["domain_id"] = domain_map[name]

    max_source_id = max(q["id"] for q in raw)
    parts = write(prepared, len(domain_map), dropped, max_source_id)

    print(f"wrote {parts} part file(s) + 99_finalize.sql to {OUT_DIR.relative_to(ROOT)}")
    print(f"  questions: {len(prepared)}")
    print(f"  skipped:   {dict(skipped) or 'none'}")
    print(f"  correct_index spread: {dict(sorted(Counter(r['correct_index'] for r in prepared).items()))}")
    by_domain = Counter(r["domain_id"] for r in prepared)
    print(f"  per-domain: {dict(sorted(by_domain.items()))}")


def parse_domain_ids() -> dict[str, int]:
    """Read the (id -> English name) mapping out of 02_seed_domains.sql."""
    src = (ROOT / "db" / "02_seed_domains.sql").read_text(encoding="utf-8")
    mapping: dict[str, int] = {}
    for line in src.splitlines():
        line = line.strip()
        if not line.startswith("(") or "'en'" not in line:
            continue
        head, _, rest = line.partition(",")
        domain_id = int(head.lstrip("("))
        name = rest.split("'en',", 1)[1].strip().rstrip(",").rstrip(")").strip()
        mapping[name[1:-1].replace("''", "'")] = domain_id
    return mapping


def write(rows: list[dict], n_domains: int, dropped: list[int], max_source_id: int) -> None:
    """Emit the seed as numbered statement files small enough for the SQL editor."""
    statements: list[str] = []

    for start in range(0, len(rows), BATCH):
        chunk = rows[start : start + BATCH]
        statements.append(
            "insert into public.questions (id, domain_id, correct_index, difficulty, is_active) values\n"
            + ",\n".join(
                f"({r['id']},{r['domain_id']},{r['correct_index']},{sql_str(r['difficulty'])},true)"
                for r in chunk
            )
            + "\non conflict (id) do update set\n"
              "  domain_id = excluded.domain_id,\n"
              "  correct_index = excluded.correct_index,\n"
              "  difficulty = excluded.difficulty,\n"
              "  is_active = true;\n"
        )

    for start in range(0, len(rows), BATCH // 5):
        chunk = rows[start : start + BATCH // 5]
        values = []
        for r in chunk:
            for lang in LANGS:
                options = json.dumps([o[lang] for o in r["options"]], ensure_ascii=False)
                values.append(
                    f"({r['id']},{sql_str(lang)},{sql_str(r['text'][lang])},{sql_str(options)})"
                )
        statements.append(
            "insert into public.question_translations (question_id, language_code, text, options) values\n"
            + ",\n".join(values)
            + "\non conflict (question_id, language_code) do update set\n"
              "  text = excluded.text,\n"
              "  options = excluded.options;\n"
        )

    # Group whole statements into files, never splitting one across a boundary.
    files: list[list[str]] = [[]]
    size = 0
    for statement in statements:
        encoded = len(statement.encode("utf-8"))
        if files[-1] and size + encoded > MAX_FILE_BYTES:
            files.append([])
            size = 0
        files[-1].append(statement)
        size += encoded

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for stale in OUT_DIR.glob("*.sql"):
        stale.unlink()

    total = len(files)
    for index, group in enumerate(files, start=1):
        body = HEADER.format(part=index, total=total) + "\n".join(group)
        (OUT_DIR / f"{index:02d}.sql").write_text(body, encoding="utf-8")

    # Retiring is expressed as the short list of ids the seed deliberately
    # leaves out, rather than 5 000 ids the seed does include.
    dropped_list = ", ".join(str(i) for i in sorted(dropped)) or "-1"
    retired = f"id > {max_source_id} or id in ({dropped_list})"
    (OUT_DIR / "99_finalize.sql").write_text(
        FINALIZE_HEADER
        + "-- Questions the current seed leaves out are retired, not deleted, so any\n"
          "-- historical quiz_answers keep their foreign key.\n"
          "update public.questions set is_active = false\n"
          f" where {retired};\n\n"
          "-- Their translations, on the other hand, are dead weight: nothing points\n"
          "-- at them and the RLS policy on question_translations already hides rows\n"
          "-- whose question is inactive. Scoped to exactly the ids this seed drops,\n"
          "-- so a question an admin deactivated by hand keeps its text.\n"
          "delete from public.question_translations\n"
          f" where question_id in (select id from public.questions where {retired});\n\n"
          "-- Keep the sequence ahead of the seeded ids.\n"
          "select setval('public.questions_id_seq',\n"
          "              (select coalesce(max(id), 1) from public.questions));\n",
        encoding="utf-8",
    )
    return total


if __name__ == "__main__":
    build()
