-- ============================================================
-- Sharpet — 11_flagged_questions.sql
-- "Flag as known" — lets a logged-in user park a question they already know
-- so it stops showing up in their own quizzes. Idempotent: safe to re-run.
--
-- Model
-- -----
-- One row per (user, question) in flagged_questions. Flagging/unflagging goes
-- through flag_question()/unflag_question() (SECURITY DEFINER, stamp
-- auth.uid() themselves) — same pattern as reported_questions in 05_rpc.sql.
-- Reads are a plain RLS-scoped select, same as reported_questions, so the
-- profile page can query the table directly with PostgREST embedding instead
-- of needing another RPC.
--
-- get_quiz_questions() is recreated with its existing 5-argument signature
-- (see 09_region_block.sql) to exclude a caller's own flagged questions —
-- no arity change, so no drop is needed first.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Table
-- ------------------------------------------------------------
create table if not exists public.flagged_questions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  question_id int references public.questions(id) on delete cascade not null,
  flagged_at timestamptz default now(),
  unique (user_id, question_id)
);

create index if not exists idx_flagged_questions_user
  on public.flagged_questions(user_id, flagged_at desc);

alter table public.flagged_questions enable row level security;

revoke all on table public.flagged_questions from anon, authenticated;
grant select on table public.flagged_questions to authenticated;

drop policy if exists "users see own flagged questions" on public.flagged_questions;
create policy "users see own flagged questions"
  on public.flagged_questions for select using (auth.uid() = user_id);

-- ------------------------------------------------------------
-- 2. flag_question — stamps user_id server-side and rate-limits.
-- ------------------------------------------------------------
create or replace function public.flag_question(p_question_id int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.questions q where q.id = p_question_id) then
    raise exception 'question not found' using errcode = '22023';
  end if;

  perform public.check_rate_limit('flag_question', 60, interval '10 minutes');

  insert into public.flagged_questions (user_id, question_id)
  values (v_uid, p_question_id)
  on conflict (user_id, question_id) do nothing;
end;
$$;

revoke all on function public.flag_question(int) from public, anon, authenticated;
grant execute on function public.flag_question(int) to authenticated;

-- ------------------------------------------------------------
-- 3. unflag_question
-- ------------------------------------------------------------
create or replace function public.unflag_question(p_question_id int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  delete from public.flagged_questions
   where user_id = v_uid and question_id = p_question_id;
end;
$$;

revoke all on function public.unflag_question(int) from public, anon, authenticated;
grant execute on function public.unflag_question(int) to authenticated;

-- ------------------------------------------------------------
-- 4. get_quiz_questions — exclude the caller's own flagged questions.
--    Same 5-arg signature as 09_region_block.sql, just adding one predicate;
--    a guest (auth.uid() is null) never has flagged rows, so this is a no-op
--    for guest play.
-- ------------------------------------------------------------
create or replace function public.get_quiz_questions(
  p_domain_ids      int[],
  p_language        text,
  p_num_options     int,
  p_limit           int,
  p_turnstile_token text default null
)
returns setof public.quiz_question_row
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_num_options int := least(greatest(coalesce(p_num_options, 3), 2), 4);
  v_limit       int := least(greatest(coalesce(p_limit, 10), 1), 100);
  v_is_guest    boolean := auth.uid() is null;
  v_row         public.quiz_question_row;
  v_idx         int[];
  r             record;
begin
  if not v_is_guest and coalesce((select is_banned from public.profiles where id = auth.uid()), false) then
    raise exception 'account suspended' using errcode = '42501';
  end if;

  if v_is_guest and public.is_region_blocked() then
    raise exception 'this feature is not available in your region' using errcode = '42501';
  end if;

  perform public.check_rate_limit(
    'get_quiz_questions',
    private.setting_int('rate_limit_get_quiz_questions_max', 10),
    make_interval(mins => private.setting_int('rate_limit_get_quiz_questions_window_minutes', 10))
  );

  if v_is_guest and not public.verify_turnstile(p_turnstile_token) then
    raise exception 'captcha verification failed' using errcode = '42501';
  end if;

  if p_language is null or p_language not in ('en','de','cs') then
    raise exception 'unsupported language' using errcode = '22023';
  end if;
  if p_domain_ids is null or coalesce(array_length(p_domain_ids, 1), 0) = 0 then
    raise exception 'at least one domain is required' using errcode = '22023';
  end if;
  if coalesce(array_length(p_domain_ids, 1), 0) > 50 then
    raise exception 'too many domains' using errcode = '22023';
  end if;

  perform private.log_usage_event('quiz_start', v_is_guest);

  for r in
    select q.id, q.domain_id, q.correct_index,
           jsonb_array_length(qt.options) as n_options
    from public.questions q
    join public.question_translations qt
      on qt.question_id = q.id
     and qt.language_code = p_language
    where q.is_active
      and q.domain_id = any (p_domain_ids)
      and q.correct_index >= 0
      and q.correct_index < jsonb_array_length(qt.options)
      and (not v_is_guest or q.is_guest_demo)
      and not exists (
        select 1 from public.flagged_questions fq
        where fq.user_id = auth.uid() and fq.question_id = q.id
      )
    order by random()
    limit v_limit
  loop
    select array_agg(x.i order by random())
      into v_idx
    from (
      select r.correct_index as i
      union all
      select d.i from (
        select gs as i
        from generate_series(0, r.n_options - 1) gs
        where gs <> r.correct_index
        order by random()
        limit v_num_options - 1
      ) d
    ) x;

    select jsonb_object_agg(t.language_code, t.text),
           jsonb_object_agg(t.language_code, (
             select jsonb_agg(t.options -> u.i order by u.ord)
             from unnest(v_idx) with ordinality u(i, ord)
           ))
      into v_row.texts, v_row.options
    from public.question_translations t
    where t.question_id = r.id;

    v_row.question_id := r.id;
    v_row.domain_id   := r.domain_id;
    return next v_row;
  end loop;
end;
$$;

revoke all on function public.get_quiz_questions(int[], text, int, int, text) from public;
grant execute on function public.get_quiz_questions(int[], text, int, int, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 5. Default privileges
-- ------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
