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
-- Stub out Turnstile for this run.
-- get_quiz_questions() now requires a verified captcha token for any caller
-- with no auth.uid() (see db/06_hardening.sql), which is exactly the
-- context most of this script runs assertions in before "set role anon" /
-- "set role authenticated" get to a real jwt claim. verify_turnstile()
-- calls a live Cloudflare endpoint this offline harness has no route to and
-- has no real site/secret key for, so it's the one piece of 06 that can't
-- be exercised here — everything else (rate limiting, RLS, the RPC logic
-- itself) still runs for real. Swap this back out if you ever wire a real
-- Turnstile test key into the harness.
create or replace function public.verify_turnstile(p_token text)
returns boolean
language sql
as $$ select true; $$;

-- This whole section predates the guest-only demo pool (db/09_region_block.sql)
-- and is explicitly meant to exercise get_quiz_questions unrestricted, so it
-- impersonates alice (authenticated) rather than a guest — otherwise every
-- assertion below would silently start seeing only the ~100-question demo
-- pool instead of the full active bank, since this section runs as the
-- superuser with no jwt claim set, which auth.uid() reads as "guest" same
-- as an anonymous caller.
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

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

-- Guest demo pool (db/09_region_block.sql): a guest never sees a question
-- outside the fixed, curated pool, no matter how many domains they ask for.
do $$
declare
  v_ids             int[];
  v_non_demo_count  int;
begin
  perform pg_temp.check('region_status() is false for a guest with no country header',
    public.region_status() = false);

  select array_agg(question_id) into v_ids
    from public.get_quiz_questions(
      array[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17], 'en', 3, 100, 'any-token');

  perform pg_temp.check('the demo pool actually returns some questions',
    coalesce(array_length(v_ids, 1), 0) > 0);

  select count(*) into v_non_demo_count
    from public.questions
   where id = any(v_ids) and not is_guest_demo;
  perform pg_temp.check('a guest only ever gets questions from the demo pool',
    v_non_demo_count = 0);
end $$;

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

-- ======================================================================
-- GEO (db/08_geo.sql)
-- ======================================================================
-- client_country() is revoked from anon/authenticated (it's an internal
-- helper, same as client_ip()) — check it as the superuser, which owns it
-- and so isn't subject to that revoke.
reset role;
select pg_temp.check('client_country() returns null rather than erroring when there is no cf-ipcountry header',
  public.client_country() is null);

-- ======================================================================
-- ADMIN LAYER (db/07_admin.sql)
-- ======================================================================
reset role;

-- Promote alice directly (bypassing the RPC — there's no admin yet to call
-- it with) to get a test fixture. The real bootstrap path is the one-time
-- UPDATE in 07_admin.sql keyed to a real e-mail address.
update public.profiles set is_admin = true
where id = '11111111-1111-1111-1111-111111111111';

set role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);

do $$
declare ok boolean;
begin
  perform pg_temp.check('is_admin() is false for a non-admin', public.is_admin() = false);

  begin
    perform public.admin_list_users(null, 10, 0);
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('a non-admin cannot call admin_list_users', ok);

  begin
    perform public.admin_set_user_active('11111111-1111-1111-1111-111111111111', false);
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('a non-admin cannot deactivate anyone', ok);
end $$;

reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

do $$
declare
  ok      boolean;
  n_users int;
  domain_name text;
  import_res  jsonb;
begin
  perform pg_temp.check('is_admin() is true for alice', public.is_admin());

  select count(*) into n_users from public.admin_list_users(null, 100, 0);
  perform pg_temp.check('admin_list_users returns rows including bob',
    n_users >= 2);

  perform public.admin_set_user_active('22222222-2222-2222-2222-222222222222', false);
  perform pg_temp.check('admin_set_user_active bans bob',
    (select is_banned from public.profiles where id = '22222222-2222-2222-2222-222222222222'));

  begin
    perform public.admin_set_user_admin('11111111-1111-1111-1111-111111111111', false);
    ok := false;
  exception when others then ok := true;
  end;
  perform pg_temp.check('an admin cannot remove their own admin access', ok);

  begin
    perform public.admin_set_setting('not_a_real_key', '5');
    ok := false;
  exception when others then ok := true;
  end;
  perform pg_temp.check('admin_set_setting rejects an unknown key', ok);

  perform public.admin_set_setting('rate_limit_get_quiz_questions_max', '42');
  perform pg_temp.check('admin_set_setting persists a known key',
    (select value from public.admin_get_settings() where key = 'rate_limit_get_quiz_questions_max') = '42');

  begin
    perform public.admin_set_setting('rate_limit_get_quiz_questions_max', 'not-a-number');
    ok := false;
  exception when others then ok := true;
  end;
  perform pg_temp.check('admin_set_setting rejects a non-numeric value for an int setting', ok);

  select dt.name into domain_name
    from public.domain_translations dt
   where dt.language_code = 'en'
   limit 1;

  import_res := public.admin_upsert_questions_csv(jsonb_build_array(
    jsonb_build_object(
      'domain', domain_name, 'difficulty', 'easy',
      'text_en', 'admin test question — csv import', 'text_de', 'admin test question — csv import (de)',
      'text_cs', 'admin test question — csv import (cs)',
      'option1_en', 'A', 'option1_de', 'A', 'option1_cs', 'A',
      'option2_en', 'B', 'option2_de', 'B', 'option2_cs', 'B',
      'correct_option', '1'
    ),
    jsonb_build_object('domain', '', 'text_en', 'missing everything else')
  ));
  perform pg_temp.check('admin_upsert_questions_csv creates a valid new row',
    (import_res ->> 'created')::int = 1);
  perform pg_temp.check('admin_upsert_questions_csv flags the malformed row invalid',
    (import_res ->> 'invalid')::int = 1);

  -- Re-importing the exact same valid row is a duplicate, not a second create.
  import_res := public.admin_upsert_questions_csv(jsonb_build_array(
    jsonb_build_object(
      'domain', domain_name, 'difficulty', 'easy',
      'text_en', 'admin test question — csv import', 'text_de', 'admin test question — csv import (de)',
      'text_cs', 'admin test question — csv import (cs)',
      'option1_en', 'A', 'option1_de', 'A', 'option1_cs', 'A',
      'option2_en', 'B', 'option2_de', 'B', 'option2_cs', 'B',
      'correct_option', '1'
    )
  ));
  perform pg_temp.check('re-importing the same row is a duplicate, not a create',
    (import_res ->> 'duplicates')::int = 1 and (import_res ->> 'created')::int = 0);

  perform pg_temp.check('admin actions land in the audit log',
    (select count(*) from public.admin_list_audit_log(500, 0)) >= 4);
end $$;

-- Region blocking (db/09_region_block.sql): the text-kind setting and the
-- manual IP ban list.
do $$
declare
  ok       boolean;
  v_ban_id bigint;
begin
  perform public.admin_set_setting('blocked_continents', 'Asia,Africa,South America');
  perform pg_temp.check('admin_set_setting accepts a text-kind setting',
    (select value from public.admin_get_settings() where key = 'blocked_continents')
      = 'Asia,Africa,South America');

  begin
    perform public.admin_set_setting('blocked_continents', '');
    ok := false;
  exception when others then ok := true;
  end;
  perform pg_temp.check('admin_set_setting rejects an empty text-kind value', ok);

  perform public.admin_add_ip_ban('203.0.113.0/24', 'test range');
  -- admin_list_ip_bans(), not the table directly: ip_bans has no grants for
  -- authenticated at all, by design, same as every other admin-only table.
  select id into v_ban_id from public.admin_list_ip_bans() where cidr = '203.0.113.0/24';
  perform pg_temp.check('admin_add_ip_ban records the ban',
    (select count(*) from public.admin_list_ip_bans() where cidr = '203.0.113.0/24') = 1);

  begin
    perform public.admin_add_ip_ban('not-an-ip', null);
    ok := false;
  exception when others then ok := true;
  end;
  perform pg_temp.check('admin_add_ip_ban rejects a malformed range', ok);

  perform public.admin_remove_ip_ban(v_ban_id);
  perform pg_temp.check('admin_remove_ip_ban removes it',
    (select count(*) from public.admin_list_ip_bans() where cidr = '203.0.113.0/24') = 0);
end $$;

-- Bob is banned from the block above — gameplay-writing RPCs must now
-- refuse him even though he's still a valid, logged-in user.
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);

do $$
declare ok boolean;
begin
  begin
    perform public.start_quiz_session(array[1], 'en', 3, 5);
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  perform pg_temp.check('a deactivated user cannot start a quiz session', ok);
end $$;

reset role;
delete from auth.users where email in ('alice@test.local','bob@test.local');
select 'ALL SECURITY TESTS PASSED' as result;
