-- ============================================================
-- Sharpet — 10_user_submissions.sql  (v2 — day/night model)
-- Lets ANY logged-in user submit new questions (single or batch, e.g. from
-- an external source). Only free, deterministic checks run synchronously;
-- everything else sits in staging until a nightly pass (run by an AI agent
-- with direct database access, not a per-row API call) resolves it. This
-- keeps the submit path instant and free, and keeps the expensive semantic
-- work batched and off the interactive path entirely.
--
-- What's mandatory per row: domain, one language's question text, and one
-- correct answer in that language. Everything else — other languages,
-- extra wrong-answer options — is optional and can be filled in later by
-- the nightly pass. This deliberately differs from admin_upsert_questions_
-- csv (07_admin.sql), which still requires all three languages up front —
-- that path is for trusted, complete, curated batches; this one is for
-- partial, sourced-from-anywhere input.
--
-- Synchronous (this file, at submit time — free, instant):
--   * structural validation (domain exists, at least one complete language,
--     option counts consistent across whatever languages were given,
--     correct_option in range)
--   * exact-duplicate check: normalized text match against existing
--     question_translations in the same language. Catches literal
--     re-submissions immediately, for free.
-- Deferred to the nightly pass (not in this file):
--   * "does this answer already exist, and if so is the question context
--     the same one" semantic judgement
--   * generating missing languages / missing distractor options
--   * updating question_submissions.status to 'needs_review', 'approved',
--     or 'rejected', and only 'needs_review' rows ever surface in the
--     admin UI — most rows should resolve automatically overnight.
--
-- This file assumes 01–07 have already been applied (09 optional).
-- ============================================================

create extension if not exists pg_trgm;

-- Kept for the nightly pass's own use (narrowing candidates by text
-- similarity before a judgement call) — not used anywhere in this file.
create index if not exists idx_question_translations_text_trgm
  on public.question_translations using gin (text gin_trgm_ops);

-- ------------------------------------------------------------
-- 1. Submissions table.
--    translations is a jsonb object keyed by whichever of en/de/cs were
--    actually supplied, e.g. {"en": {"text": "...", "options": ["Paris"]}}.
--    A row with just one language and one option (no distractors) is
--    valid and expected — that's the minimum the nightly pass has to work
--    with, not an error state.
-- ------------------------------------------------------------
create table if not exists public.question_submissions (
  id                  bigserial primary key,
  submitted_by        uuid references auth.users(id) on delete set null,
  source              text,
  domain_id           int references public.domains(id),
  difficulty          text not null default 'medium'
                       check (difficulty in ('easy','medium','hard')),
  translations        jsonb not null check (jsonb_typeof(translations) = 'object'),
  correct_index       int not null default 0,
  status              text not null default 'pending'
                       check (status in ('pending','duplicate','needs_review','approved','rejected')),
  exact_match_question_id int references public.questions(id),
  matched_question_id     int references public.questions(id),   -- filled in by the nightly pass
  similarity_score        numeric,                                -- filled in by the nightly pass
  ai_notes                text,                                   -- nightly pass's reasoning, for the audit trail
  resulting_question_id   int references public.questions(id),
  reviewed_by          uuid references auth.users(id) on delete set null,
  reviewed_at          timestamptz,
  created_at           timestamptz not null default now()
);

create index if not exists idx_question_submissions_status on public.question_submissions(status);
create index if not exists idx_question_submissions_submitter on public.question_submissions(submitted_by);

alter table public.question_submissions enable row level security;
-- No policies: same pattern as quiz_sessions etc — clients get everything
-- through SECURITY DEFINER RPCs below, never direct table access. The
-- nightly pass runs with full database access (not through PostgREST), so
-- RLS/grants here don't apply to it regardless.
revoke all on table public.question_submissions from anon, authenticated, public;

-- ------------------------------------------------------------
-- 2. A locked-down view the nightly pass uses to do "does this answer
--    already exist" lookups. This deliberately mirrors questions.
--    correct_index the same way the gameplay RPCs do internally — it must
--    NEVER be granted to anon/authenticated, since that would leak the
--    answer key the rest of this schema goes out of its way to protect.
-- ------------------------------------------------------------
create or replace view public.question_correct_answers as
select q.id as question_id, q.domain_id, q.is_active, qt.language_code,
       qt.text as question_text,
       qt.options ->> q.correct_index as correct_answer_text
from public.questions q
join public.question_translations qt on qt.question_id = q.id;

revoke all on public.question_correct_answers from anon, authenticated, public;

-- ------------------------------------------------------------
-- 3. submit_questions_batch — the user-facing entry point. Every row that
--    passes structural validation lands in staging as 'pending' unless an
--    exact duplicate is found; nothing is ever auto-inserted into the live
--    question bank from here.
--    p_rows: jsonb array of {domain, difficulty?, correct_option?,
--      text_en?, text_de?, text_cs?, option1_en..option4_cs?} — same
--      column names the admin CSV importer uses, so the same file format
--      works for both, just with fewer fields required here.
-- ------------------------------------------------------------
create or replace function public.submit_questions_batch(p_rows jsonb, p_source text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := auth.uid();
  v_row          jsonb;
  v_row_num      int := 0;
  v_pending      int := 0;
  v_duplicates   int := 0;
  v_invalid      int := 0;
  v_errors       jsonb := '[]'::jsonb;

  v_domain_name  text;
  v_domain_id    int;
  v_difficulty   text;
  v_langs        text[] := array['en','de','cs'];
  v_lang         text;
  v_text         text;
  v_opts         jsonb;
  v_slot         text;
  v_translations jsonb;
  v_provided     text[];
  v_n_opts       int;
  v_this_n       int;
  v_correct_opt_raw text;
  v_correct_opt  int;
  v_correct_idx  int;
  v_reason       text;
  v_exact_id     int;
  v_norm_text    text;
  i              int;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if coalesce((select is_banned from public.profiles where id = v_uid), false) then
    raise exception 'account suspended' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'batch too large — split into files of 500 rows or fewer' using errcode = '22023';
  end if;

  -- One batch call per 10 minutes per account — generous for a real person
  -- importing a source file, a real ceiling against scripted spam.
  perform public.check_rate_limit('submit_questions_batch', 10, interval '10 minutes');

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_row_num := v_row_num + 1;
    v_reason := null;
    v_translations := '{}'::jsonb;
    v_provided := array[]::text[];
    v_n_opts := null;

    v_domain_name := btrim(coalesce(v_row ->> 'domain', ''));
    v_difficulty  := lower(btrim(coalesce(nullif(v_row ->> 'difficulty', ''), 'medium')));

    foreach v_lang in array v_langs loop
      v_text := btrim(coalesce(v_row ->> ('text_' || v_lang), ''));
      v_opts := '[]'::jsonb;
      for i in 1..4 loop
        v_slot := btrim(coalesce(v_row ->> ('option' || i || '_' || v_lang), ''));
        exit when v_slot = '';  -- options must be filled contiguously from option1
        v_opts := v_opts || to_jsonb(v_slot);
      end loop;

      if v_text <> '' and jsonb_array_length(v_opts) = 0 then
        v_reason := 'answer missing for language ' || v_lang;
      elsif v_text = '' and jsonb_array_length(v_opts) > 0 then
        v_reason := 'option given without question text for language ' || v_lang;
      elsif v_text <> '' and jsonb_array_length(v_opts) > 0 then
        v_this_n := jsonb_array_length(v_opts);
        if v_n_opts is null then
          v_n_opts := v_this_n;
        elsif v_this_n <> v_n_opts then
          v_reason := 'option counts differ between provided languages';
        end if;
        if (select count(*) from jsonb_array_elements_text(v_opts) o(x) where o.x <> '') <>
           (select count(distinct o.x) from jsonb_array_elements_text(v_opts) o(x)) then
          v_reason := 'duplicate options in the ' || v_lang || ' column';
        end if;
        v_translations := v_translations || jsonb_build_object(v_lang, jsonb_build_object('text', v_text, 'options', v_opts));
        v_provided := v_provided || v_lang;
      end if;
    end loop;

    if v_reason is null and array_length(v_provided, 1) is null then
      v_reason := 'need at least one language with question text and an answer';
    end if;
    if v_reason is null and v_domain_name = '' then v_reason := 'missing domain'; end if;
    if v_reason is null and v_difficulty not in ('easy','medium','hard') then
      v_reason := 'difficulty must be easy, medium or hard';
    end if;

    if v_reason is null then
      v_correct_opt_raw := btrim(coalesce(v_row ->> 'correct_option', ''));
      if v_correct_opt_raw = '' then
        v_correct_opt := 1;  -- a single supplied option is, by definition, the answer
      elsif v_correct_opt_raw !~ '^[0-9]+$' then
        v_reason := 'correct_option must be a number';
      else
        v_correct_opt := v_correct_opt_raw::int;
      end if;
      if v_reason is null and (v_correct_opt < 1 or v_correct_opt > v_n_opts) then
        v_reason := 'correct_option must point at one of the provided options';
      else
        v_correct_idx := v_correct_opt - 1;
      end if;
    end if;

    if v_reason is null then
      select d.id into v_domain_id
        from public.domains d
        join public.domain_translations dt on dt.domain_id = d.id and dt.language_code = 'en'
       where lower(dt.name) = lower(v_domain_name)
       limit 1;
      if v_domain_id is null then
        v_reason := 'unknown domain: ' || v_domain_name;
      end if;
    end if;

    if v_reason is not null then
      v_invalid := v_invalid + 1;
      v_errors := v_errors || jsonb_build_object('row', v_row_num, 'reason', v_reason);
      continue;
    end if;

    begin
      -- Exact-duplicate check, per provided language, first match wins.
      v_exact_id := null;
      foreach v_lang in array v_provided loop
        v_norm_text := regexp_replace(lower(v_translations -> v_lang ->> 'text'), '\s+', ' ', 'g');
        select qt.question_id into v_exact_id
          from public.question_translations qt
         where qt.language_code = v_lang
           and regexp_replace(lower(qt.text), '\s+', ' ', 'g') = v_norm_text
         limit 1;
        exit when v_exact_id is not null;
      end loop;

      if v_exact_id is not null then
        insert into public.question_submissions
          (submitted_by, source, domain_id, difficulty, translations, correct_index,
           status, exact_match_question_id)
        values
          (v_uid, p_source, v_domain_id, v_difficulty, v_translations, v_correct_idx,
           'duplicate', v_exact_id);
        v_duplicates := v_duplicates + 1;
      else
        insert into public.question_submissions
          (submitted_by, source, domain_id, difficulty, translations, correct_index, status)
        values
          (v_uid, p_source, v_domain_id, v_difficulty, v_translations, v_correct_idx, 'pending');
        v_pending := v_pending + 1;
      end if;
    exception when others then
      v_invalid := v_invalid + 1;
      v_errors := v_errors || jsonb_build_object('row', v_row_num, 'reason', 'unexpected error: ' || sqlerrm);
    end;
  end loop;

  perform private.log_admin_action('user_questions_submit', v_uid::text,
    jsonb_build_object('source', p_source, 'total', v_row_num, 'pending', v_pending,
                        'duplicates', v_duplicates, 'invalid', v_invalid));

  return jsonb_build_object(
    'total', v_row_num, 'pending', v_pending,
    'duplicates', v_duplicates, 'invalid', v_invalid, 'errors', v_errors
  );
end;
$$;

revoke all on function public.submit_questions_batch(jsonb, text) from public, anon;
grant execute on function public.submit_questions_batch(jsonb, text) to authenticated;

-- ------------------------------------------------------------
-- 4. Admin review queue. Populated by the nightly pass setting a row's
--    status to 'needs_review' (with matched_question_id, similarity_score
--    and ai_notes filled in) when it isn't confident enough to decide on
--    its own — most 'pending' rows should resolve to 'approved' or
--    'rejected' overnight without ever reaching this list.
-- ------------------------------------------------------------
create or replace function public.admin_list_submissions(
  p_status text default 'needs_review',
  p_limit  int  default 100,
  p_offset int  default 0
)
returns table (
  id int, submitted_by_email text, source text, domain_name text,
  difficulty text, languages text[], preview_language text, preview_text text,
  translations jsonb, correct_index int,
  status text, ai_notes text, similarity_score numeric,
  matched_question_id int, matched_question_text text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  return query
    select s.id, u.email::text, s.source, dt.name,
           s.difficulty,
           (select array_agg(k) from jsonb_object_keys(s.translations) k) as languages,
           case when s.translations ? 'en' then 'en'
                when s.translations ? 'de' then 'de'
                else 'cs' end as preview_language,
           coalesce(s.translations -> 'en' ->> 'text', s.translations -> 'de' ->> 'text', s.translations -> 'cs' ->> 'text'),
           s.translations, s.correct_index,
           s.status, s.ai_notes, s.similarity_score,
           s.matched_question_id, mqt.text,
           s.created_at
    from public.question_submissions s
    left join auth.users u on u.id = s.submitted_by
    left join public.domain_translations dt on dt.domain_id = s.domain_id and dt.language_code = 'en'
    left join public.question_translations mqt on mqt.question_id = s.matched_question_id and mqt.language_code = 'en'
    where p_status is null or s.status = p_status
    order by s.created_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.admin_list_submissions(text, int, int) from public, anon, authenticated;
grant execute on function public.admin_list_submissions(text, int, int) to authenticated;

create or replace function public.admin_review_submission(p_submission_id int, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub public.question_submissions%rowtype;
  v_new_qid int;
  v_lang text;
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  select * into v_sub from public.question_submissions where id = p_submission_id;
  if not found then
    raise exception 'submission not found' using errcode = '22023';
  end if;
  if v_sub.status <> 'needs_review' then
    raise exception 'submission already resolved' using errcode = '22023';
  end if;

  if p_approve then
    insert into public.questions (domain_id, correct_index, difficulty, is_active)
    values (v_sub.domain_id, v_sub.correct_index, v_sub.difficulty, true)
    returning id into v_new_qid;

    for v_lang in select jsonb_object_keys(v_sub.translations) loop
      insert into public.question_translations (question_id, language_code, text, options)
      values (v_new_qid, v_lang, v_sub.translations -> v_lang ->> 'text', v_sub.translations -> v_lang -> 'options');
    end loop;

    update public.question_submissions
       set status = 'approved', resulting_question_id = v_new_qid,
           reviewed_by = auth.uid(), reviewed_at = now()
     where id = p_submission_id;
  else
    update public.question_submissions
       set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
     where id = p_submission_id;
  end if;

  perform private.log_admin_action(
    case when p_approve then 'submission_approve' else 'submission_reject' end,
    p_submission_id::text, jsonb_build_object('resulting_question_id', v_new_qid));

  return jsonb_build_object('approved', p_approve, 'resulting_question_id', v_new_qid);
end;
$$;

revoke all on function public.admin_review_submission(int, boolean) from public, anon, authenticated;
grant execute on function public.admin_review_submission(int, boolean) to authenticated;

-- ------------------------------------------------------------
-- 5. Default privileges
-- ------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
