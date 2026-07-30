-- ============================================================
-- Sharpet — 05_rpc.sql
-- Server-side gameplay API. Idempotent: safe to re-run.
--
-- Why these exist
-- ---------------
-- Previously the browser fetched questions.correct_index directly and then
-- told the database whether it had answered correctly. That meant (a) the
-- whole answer key was one anonymous SELECT away, and (b) any client could
-- write arbitrary scores into its own history.
--
-- Now:
--   get_quiz_questions()  hands out questions with the options already
--                         trimmed and shuffled — and no answer key.
--   submit_quiz_answer()  grades on the server and is the only writer of
--                         quiz_answers.
--   finish_quiz_session() recomputes the session totals from the stored
--                         answers rather than trusting a client-sent number.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Clean slate (types are dropped with cascade, so drop functions first)
-- ------------------------------------------------------------
drop function if exists public.get_quiz_questions(int[], text, int, int);
drop function if exists public.submit_quiz_answer(int, text, text, int, uuid);
drop function if exists public.start_quiz_session(int[], text, int, int);
drop function if exists public.finish_quiz_session(uuid);
drop function if exists public.report_question(int, text, text, uuid);

drop type if exists public.quiz_question_row cascade;
drop type if exists public.quiz_answer_result cascade;
drop type if exists public.quiz_session_result cascade;

-- All three languages are served together, sharing one shuffle, so switching
-- language mid-quiz is a pure client-side relabel: no refetch, and the option
-- the player is looking at stays in the same place.
create type public.quiz_question_row as (
  question_id int,
  domain_id   int,
  texts       jsonb,   -- {"en": "...", "de": "...", "cs": "..."}
  options     jsonb    -- {"en": [...], ...} — trimmed, shuffled, same order in every language
);

create type public.quiz_answer_result as (
  is_correct     boolean,
  correct_option text
);

create type public.quiz_session_result as (
  correct_count  int,
  total_answered int
);

-- ------------------------------------------------------------
-- 1. get_quiz_questions
--    Returns a random set of active questions in the requested domains.
--    Each question is served with the correct answer plus (n-1) randomly
--    chosen distractors, shuffled — the position carries no information, and
--    the answer key never leaves the server.
-- ------------------------------------------------------------
create function public.get_quiz_questions(
  p_domain_ids  int[],
  p_language    text,
  p_num_options int,
  p_limit       int
)
returns setof public.quiz_question_row
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_num_options int := least(greatest(coalesce(p_num_options, 3), 2), 4);
  v_limit       int := least(greatest(coalesce(p_limit, 10), 1), 100);
  v_row         public.quiz_question_row;
  v_idx         int[];
  r             record;
begin
  -- p_language is validated even though every language is returned: it keeps
  -- a typo in the caller loud instead of silently serving the wrong thing.
  if p_language is null or p_language not in ('en','de','cs') then
    raise exception 'unsupported language' using errcode = '22023';
  end if;
  if p_domain_ids is null or coalesce(array_length(p_domain_ids, 1), 0) = 0 then
    raise exception 'at least one domain is required' using errcode = '22023';
  end if;
  if coalesce(array_length(p_domain_ids, 1), 0) > 50 then
    raise exception 'too many domains' using errcode = '22023';
  end if;

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
    order by random()
    limit v_limit
  loop
    -- Pick which stored options to serve: the correct one plus (n-1) others,
    -- then shuffle. The same index order is reused for every language, so the
    -- three translations stay aligned.
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

-- ------------------------------------------------------------
-- 2. start_quiz_session — the only way a quiz_sessions row is created
-- ------------------------------------------------------------
create function public.start_quiz_session(
  p_domain_ids    int[],
  p_language      text,
  p_num_options   int,
  p_num_questions int
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_language is null or p_language not in ('en','de','cs') then
    raise exception 'unsupported language' using errcode = '22023';
  end if;
  if p_domain_ids is null or coalesce(array_length(p_domain_ids, 1), 0) = 0 then
    raise exception 'at least one domain is required' using errcode = '22023';
  end if;

  -- Cheap abuse brake: no more than 60 sessions started per hour per user.
  if (select count(*) from public.quiz_sessions s
      where s.user_id = v_uid and s.started_at > now() - interval '1 hour') >= 60 then
    raise exception 'too many sessions started, please slow down' using errcode = '53400';
  end if;

  insert into public.quiz_sessions
    (user_id, domain_ids, language_code, num_answer_options, num_questions)
  values
    (v_uid,
     p_domain_ids,
     p_language,
     least(greatest(coalesce(p_num_options, 3), 2), 4),
     least(greatest(coalesce(p_num_questions, 10), 1), 100))
  returning id into v_id;

  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 3. submit_quiz_answer — grades server-side, then (for a logged-in user
--    with a live session) records the answer. The caller never learns the
--    correct answer before committing to a choice.
-- ------------------------------------------------------------
create function public.submit_quiz_answer(
  p_question_id     int,
  p_language        text,
  p_selected_option text,
  p_selected_index  int  default 0,
  p_session_id      uuid default null
)
returns public.quiz_answer_result
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid            uuid := auth.uid();
  v_correct_index  int;
  v_domain_id      int;
  v_options        jsonb;
  v_result         public.quiz_answer_result;
begin
  if p_language is null or p_language not in ('en','de','cs') then
    raise exception 'unsupported language' using errcode = '22023';
  end if;

  select q.correct_index, q.domain_id, qt.options
    into v_correct_index, v_domain_id, v_options
  from public.questions q
  join public.question_translations qt
    on qt.question_id = q.id
   and qt.language_code = p_language
  where q.id = p_question_id
    and q.is_active;

  if not found or v_correct_index >= jsonb_array_length(v_options) then
    raise exception 'question not found' using errcode = '22023';
  end if;

  v_result.correct_option := v_options ->> v_correct_index;
  v_result.is_correct := (p_selected_option is not null
                          and p_selected_option = v_result.correct_option);

  if p_session_id is not null and v_uid is not null
     and exists (select 1 from public.quiz_sessions s
                 where s.id = p_session_id
                   and s.user_id = v_uid
                   and s.ended_at is null)
  then
    insert into public.quiz_answers
      (session_id, question_id, domain_id, selected_index, is_correct)
    values
      (p_session_id, p_question_id, v_domain_id,
       least(greatest(coalesce(p_selected_index, 0), 0), 9),
       v_result.is_correct)
    on conflict (session_id, question_id) do nothing;
  end if;

  return v_result;
end;
$$;

-- ------------------------------------------------------------
-- 4. finish_quiz_session — totals are recomputed from quiz_answers,
--    never taken from the client
-- ------------------------------------------------------------
create function public.finish_quiz_session(p_session_id uuid)
returns public.quiz_session_result
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_res public.quiz_session_result;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not exists (select 1 from public.quiz_sessions s
                 where s.id = p_session_id and s.user_id = v_uid) then
    raise exception 'session not found' using errcode = '42501';
  end if;

  select count(*) filter (where qa.is_correct)::int, count(*)::int
    into v_res.correct_count, v_res.total_answered
  from public.quiz_answers qa
  where qa.session_id = p_session_id;

  update public.quiz_sessions
     set correct_count  = v_res.correct_count,
         total_answered = v_res.total_answered,
         ended_at       = coalesce(ended_at, now())
   where id = p_session_id
     and user_id = v_uid;

  return v_res;
end;
$$;

-- ------------------------------------------------------------
-- 5. report_question — stamps user_id server-side and rate-limits.
--    Requires a signed-in user: the previous `insert with check (true)`
--    policy let anyone file unlimited reports under any user_id.
-- ------------------------------------------------------------
create function public.report_question(
  p_question_id int,
  p_language    text,
  p_reason      text default null,
  p_session_id  uuid default null
)
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
  if p_language is null or p_language not in ('en','de','cs') then
    raise exception 'unsupported language' using errcode = '22023';
  end if;
  if not exists (select 1 from public.questions q where q.id = p_question_id) then
    raise exception 'question not found' using errcode = '22023';
  end if;

  if (select count(*) from public.reported_questions r
      where r.user_id = v_uid and r.created_at > now() - interval '1 hour') >= 20 then
    raise exception 'too many reports, please slow down' using errcode = '53400';
  end if;

  -- Ignore a repeat report of the same question while the first is still open.
  if exists (select 1 from public.reported_questions r
             where r.user_id = v_uid
               and r.question_id = p_question_id
               and not r.resolved) then
    return;
  end if;

  insert into public.reported_questions
    (question_id, user_id, session_id, language_code, reason)
  values
    (p_question_id,
     v_uid,
     (select s.id from public.quiz_sessions s
       where s.id = p_session_id and s.user_id = v_uid),
     p_language,
     left(regexp_replace(coalesce(p_reason, ''), '[[:cntrl:]]', '', 'g'), 500));
end;
$$;

-- ------------------------------------------------------------
-- 6. Execute privileges — explicit, not inherited from PUBLIC
-- ------------------------------------------------------------
revoke all on function public.get_quiz_questions(int[], text, int, int)   from public;
revoke all on function public.submit_quiz_answer(int, text, text, int, uuid) from public;
revoke all on function public.start_quiz_session(int[], text, int, int)   from public;
revoke all on function public.finish_quiz_session(uuid)                   from public;
revoke all on function public.report_question(int, text, text, uuid)      from public;

-- Guests may play, they just cannot persist anything.
grant execute on function public.get_quiz_questions(int[], text, int, int)   to anon, authenticated;
grant execute on function public.submit_quiz_answer(int, text, text, int, uuid) to anon, authenticated;

grant execute on function public.start_quiz_session(int[], text, int, int) to authenticated;
grant execute on function public.finish_quiz_session(uuid)                 to authenticated;
grant execute on function public.report_question(int, text, text, uuid)    to authenticated;
