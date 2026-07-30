-- ============================================================
-- Sharpet — db/tests/security_tests.sql
-- Regression tests for the RLS / RPC security model.
--
-- Run against a scratch database that has had 01→05 applied:
--   psql -v ON_ERROR_STOP=1 -f db/tests/security_tests.sql
-- Every check raises an exception on failure, so a clean run means pass.
-- Must be run by a superuser (it switches into anon / authenticated).
-- ============================================================

set client_min_messages = notice;

create or replace function pg_temp.check(p_label text, p_ok boolean)
returns void language plpgsql as $$
begin
  if p_ok then
    raise notice 'PASS  %', p_label;
  else
    raise exception 'FAIL  %', p_label;
  end if;
end $$;

-- Records what an assertion needs to survive a role switch.
create temp table scratch (k text primary key, v text);
grant all on scratch to anon, authenticated;

-- ----------------------------------------------------------------------
-- Fixtures
-- ----------------------------------------------------------------------
delete from auth.users where email in ('alice@test.local','bob@test.local');

insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.local', '{"display_name":"alice"}'),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.local',   '{"display_name":"bob"}');

select pg_temp.check('handle_new_user created both profiles',
  (select count(*) from public.profiles
    where id in ('11111111-1111-1111-1111-111111111111',
                 '22222222-2222-2222-2222-222222222222')) = 2);

select pg_temp.check('display_name is capped at 32 chars',
  (select count(*) from public.profiles where char_length(display_name) > 32) = 0);

-- ----------------------------------------------------------------------
-- get_quiz_questions: shape and honesty (checked with full rights)
-- ----------------------------------------------------------------------
select pg_temp.check('quiz_question_row exposes no answer key',
  not exists (
    select 1 from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    where c.relname = 'quiz_question_row' and a.attname ilike '%correct%'));

create temp table served as
  select question_id, domain_id, texts, options -> 'en' as options,
         options -> 'de' as options_de, options -> 'cs' as options_cs
  from public.get_quiz_questions(array[1,2,3,4,5], 'en', 4, 80);

select pg_temp.check('get_quiz_questions honours the row limit',
  (select count(*) from served) = 80);

select pg_temp.check('every question carries exactly the requested option count',
  (select count(*) from served where jsonb_array_length(options) <> 4) = 0);

select pg_temp.check('all three languages are served with the same option count',
  (select count(*) from served
    where jsonb_array_length(options_de) <> 4
       or jsonb_array_length(options_cs) <> 4
       or (texts ->> 'de') is null
       or (texts ->> 'cs') is null) = 0);

select pg_temp.check('the language variants share one option order',
  (select count(*) from served s
     join public.question_translations en
       on en.question_id = s.question_id and en.language_code = 'en'
     join public.question_translations de
       on de.question_id = s.question_id and de.language_code = 'de'
    where (select count(*) from jsonb_array_elements_text(s.options) with ordinality a(v, i)
             join jsonb_array_elements_text(s.options_de) with ordinality b(v, i) on a.i = b.i
            where (select min(k) from jsonb_array_elements_text(en.options) with ordinality e(v, k) where e.v = a.v)
               is distinct from
                  (select min(k) from jsonb_array_elements_text(de.options) with ordinality g(v, k) where g.v = b.v)
          ) > 0) = 0);

select pg_temp.check('options contain no duplicates',
  (select count(*) from served s
   where (select count(distinct o.val)
          from jsonb_array_elements_text(s.options) o(val)) <> 4) = 0);

select pg_temp.check('the correct answer is always among the served options',
  (select count(*)
     from served s
     join public.questions q on q.id = s.question_id
     join public.question_translations qt
       on qt.question_id = q.id and qt.language_code = 'en'
    where not (s.options ? (qt.options ->> q.correct_index))) = 0);

-- The old client took "the first N stored options", which silently dropped the
-- correct answer whenever correct_index >= N. Shuffling must spread the answer
-- across every slot instead.
select pg_temp.check('served options are shuffled across all slots',
  (select count(distinct pos) from (
     select (select min(o.ord)
               from jsonb_array_elements_text(s.options) with ordinality o(val, ord)
              where o.val = (qt.options ->> q.correct_index)) as pos
       from served s
       join public.questions q on q.id = s.question_id
       join public.question_translations qt
         on qt.question_id = q.id and qt.language_code = 'en'
   ) t) = 4);

select pg_temp.check('a 2-option game still includes the correct answer',
  (select count(*) from (
     select question_id, options -> 'en' as options
     from public.get_quiz_questions(array[2], 'en', 2, 25)
   ) s
   join public.questions q on q.id = s.question_id
   join public.question_translations qt
     on qt.question_id = q.id and qt.language_code = 'en'
   where jsonb_array_length(s.options) = 2
     and s.options ? (qt.options ->> q.correct_index)) = 25);

do $$
declare ok boolean;
begin
  begin
    perform public.get_quiz_questions(array[1], 'xx', 3, 5);
    ok := false;
  exception when others then ok := true;
  end;
  perform pg_temp.check('get_quiz_questions rejects an unknown language', ok);

  begin
    perform public.get_quiz_questions(null, 'en', 3, 5);
    ok := false;
  exception when others then ok := true;
  end;
  perform pg_temp.check('get_quiz_questions rejects an empty domain list', ok);
end $$;

select pg_temp.check('the row limit is clamped, not trusted',
  (select count(*) from public.get_quiz_questions(array[1,2,3,4,5], 'en', 3, 100000)) = 100);

-- ======================================================================
-- ANONYMOUS VISITOR
-- ======================================================================
set role anon;
select set_config('request.jwt.claim.sub', '', false);

do $$
declare ok boolean;
begin
  begin
    perform correct_index from public.questions limit 1;
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('anon cannot read questions.correct_index', ok);
end $$;

select pg_temp.check('anon can still read question ids',
  (select count(*) from public.questions) > 0);
select pg_temp.check('anon can read question text and options',
  (select count(*) from public.question_translations where language_code = 'en') > 0);
select pg_temp.check('anon can read domains',
  (select count(*) from public.domains) = 17);

do $$
declare ok boolean;
begin
  begin
    insert into public.quiz_sessions (user_id, domain_ids, num_answer_options, num_questions)
    values ('11111111-1111-1111-1111-111111111111', array[1], 3, 10);
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('anon cannot insert quiz_sessions', ok);

  begin
    insert into public.reported_questions (question_id, user_id)
    values (1, '11111111-1111-1111-1111-111111111111');
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('anon cannot forge a report under another user id', ok);

  begin
    perform public.report_question(1, 'en', 'spam', null);
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('report_question requires authentication', ok);

  begin
    perform public.start_quiz_session(array[1], 'en', 3, 5);
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('start_quiz_session requires authentication', ok);
end $$;

do $$
declare ok boolean;
begin
  begin
    perform count(*) from public.profiles;
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('anon cannot read profiles at all', ok);
end $$;

-- A guest can still play and be graded, it just is not recorded.
do $$
declare r public.quiz_answer_result;
begin
  r := public.submit_quiz_answer(1, 'en', 'definitely not the answer', 0, null);
  perform pg_temp.check('a guest gets graded', r.is_correct = false);
  perform pg_temp.check('a guest is told the right answer after answering',
    r.correct_option is not null);
end $$;

-- ======================================================================
-- ALICE (authenticated)
-- ======================================================================
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

select pg_temp.check('alice sees exactly one profile — her own',
  (select count(*) from public.profiles) = 1);

do $$
declare
  v_session uuid;
  v_qid     int;
  v_correct text;
  v_wrong   text;
  r         public.quiz_answer_result;
  totals    public.quiz_session_result;
  ok        boolean;
begin
  v_session := public.start_quiz_session(array[1,2], 'en', 3, 5);
  perform pg_temp.check('start_quiz_session returns a session id', v_session is not null);
  insert into scratch values ('session', v_session::text);

  select question_id into v_qid from public.get_quiz_questions(array[1], 'en', 3, 1);
  insert into scratch values ('qid', v_qid::text);

  -- The client cannot see the key, so the test asks submit_quiz_answer for it
  -- by deliberately answering wrong first on a throwaway (session-less) call.
  r := public.submit_quiz_answer(v_qid, 'en', '__no_such_option__', 0, null);
  v_correct := r.correct_option;
  perform pg_temp.check('a wrong answer is graded wrong', r.is_correct = false);

  select o.val into v_wrong
  from public.question_translations qt,
       jsonb_array_elements_text(qt.options) o(val)
  where qt.question_id = v_qid and qt.language_code = 'en' and o.val <> v_correct
  limit 1;

  r := public.submit_quiz_answer(v_qid, 'en', v_correct, 0, v_session);
  perform pg_temp.check('submit_quiz_answer grades a correct answer', r.is_correct);

  r := public.submit_quiz_answer(v_qid, 'en', v_wrong, 1, v_session);
  perform pg_temp.check('a question cannot be re-answered inside one session',
    (select count(*) from public.quiz_answers where session_id = v_session) = 1);

  begin
    update public.quiz_sessions set correct_count = 999 where id = v_session;
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('alice cannot hand-edit her own score', ok);

  begin
    insert into public.quiz_answers (session_id, question_id, selected_index, is_correct)
    values (v_session, 2, 0, true);
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('alice cannot inject a fabricated answer row', ok);

  totals := public.finish_quiz_session(v_session);
  perform pg_temp.check('finish_quiz_session recomputes totals from stored answers',
    totals.correct_count = 1 and totals.total_answered = 1);

  perform public.report_question(v_qid, 'en', 'none of these look right', v_session);
  perform pg_temp.check('report_question stores one report',
    (select count(*) from public.reported_questions where question_id = v_qid) = 1);

  perform public.report_question(v_qid, 'en', 'again', v_session);
  perform pg_temp.check('a duplicate open report is ignored',
    (select count(*) from public.reported_questions where question_id = v_qid) = 1);
end $$;

-- ======================================================================
-- BOB must not see or touch any of Alice's data
-- ======================================================================
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);

select pg_temp.check('bob sees none of alice''s sessions',
  (select count(*) from public.quiz_sessions) = 0);
select pg_temp.check('bob sees none of alice''s answers',
  (select count(*) from public.quiz_answers) = 0);
select pg_temp.check('bob sees none of alice''s reports',
  (select count(*) from public.reported_questions) = 0);
select pg_temp.check('bob cannot read alice''s profile',
  (select count(*) from public.profiles
    where id = '11111111-1111-1111-1111-111111111111') = 0);

do $$
declare ok boolean;
begin
  begin
    update public.profiles set id = '11111111-1111-1111-1111-111111111111'
    where id = '22222222-2222-2222-2222-222222222222';
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('bob cannot re-point his profile row at alice', ok);

  begin
    perform public.finish_quiz_session(
      (select v::uuid from scratch where k = 'session'));
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('bob cannot finish a session that is not his', ok);

  begin
    perform public.submit_quiz_answer(
      (select v::int from scratch where k = 'qid'), 'en', 'x', 0,
      (select v::uuid from scratch where k = 'session'));
    ok := true;   -- allowed to run, but must not write
  exception when others then ok := true;
  end;
  perform pg_temp.check('bob cannot append answers to alice''s session', ok);

  begin
    insert into public.friendships (user_id, friend_id)
    values ('11111111-1111-1111-1111-111111111111',
            '22222222-2222-2222-2222-222222222222');
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('bob cannot create a friendship on alice''s behalf', ok);
end $$;

reset role;
select pg_temp.check('alice''s session still holds exactly one answer',
  (select count(*) from public.quiz_answers
    where session_id = (select v::uuid from scratch where k = 'session')) = 1);

-- friendships / profile visibility -------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);

insert into public.friendships (user_id, friend_id)
values ('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111');

select pg_temp.check('a pending request does not expose the other profile',
  (select count(*) from public.profiles
    where id = '11111111-1111-1111-1111-111111111111') = 0);

reset role;
update public.friendships set status = 'accepted'
where user_id = '22222222-2222-2222-2222-222222222222';

set role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
select pg_temp.check('an accepted friend becomes visible',
  (select count(*) from public.profiles
    where id = '11111111-1111-1111-1111-111111111111') = 1);

reset role;
delete from auth.users where email in ('alice@test.local','bob@test.local');
select 'ALL SECURITY TESTS PASSED' as result;
