-- ============================================================
-- Sharpet — 07_admin.sql
-- Admin layer: user management, question moderation, a CSV bulk-import
-- path for new questions, tunable abuse parameters, an audit log, and a
-- usage dashboard. Idempotent: safe to re-run.
--
-- Architecture note
-- -----------------
-- There is still no backend. "Admin" is a normal Supabase Auth account with
-- profiles.is_admin = true, and every admin action is a SECURITY DEFINER
-- RPC that checks public.is_admin() before doing anything and writes a row
-- to admin_audit_log. This keeps the "browser only ever holds the anon
-- key" invariant intact — nothing here needs the service_role key.
--
-- "Deactivate a user" means profiles.is_banned = true, checked inside every
-- gameplay-writing RPC. It does NOT revoke an existing session or block
-- login (that needs the Auth Admin API / service_role, which this
-- architecture deliberately keeps out of the browser) — a banned user can
-- still log in and see their past history, they just can't start a quiz,
-- submit an answer, or file a report. Say so in the admin UI; don't oversell
-- it as an account lock.
--
-- This file assumes 01–06 have already been applied.
-- ============================================================

-- ------------------------------------------------------------
-- 0. profiles: is_admin / is_banned
--    Deliberately NOT added to the `update (...)` grant in 04_security.sql
--    — a client can read these (whole-table SELECT is already granted on
--    profiles) but can only change them through the RPCs below.
-- ------------------------------------------------------------
alter table public.profiles add column if not exists is_admin  boolean not null default false;
alter table public.profiles add column if not exists is_banned boolean not null default false;

-- Bootstraps the first admin so there's a way in at all. After that, use the
-- admin UI (Users → make admin) — this line is a no-op once it's already true.
update public.profiles p
   set is_admin = true
  from auth.users u
 where u.id = p.id
   and u.email = 'peter.huluk@gmail.com';

-- ------------------------------------------------------------
-- 1. is_admin() — the single check every admin RPC starts with
--    SECURITY DEFINER + explicit uid param so it's usable to check *any*
--    account (e.g. "is the target of this action also an admin"), not just
--    the caller, and doesn't depend on the calling role's grants on
--    profiles.
-- ------------------------------------------------------------
create or replace function public.is_admin(p_uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select is_admin from public.profiles where id = p_uid), false)
$$;

revoke all on function public.is_admin(uuid) from public, anon, authenticated;
-- Client code (the admin page) does need to ask "am I an admin" for itself,
-- to decide whether to show the admin UI at all — that's a convenience, the
-- real gate is every RPC checking it server-side regardless.
grant execute on function public.is_admin(uuid) to authenticated;

-- ------------------------------------------------------------
-- 2. Audit log — every admin action, human-readable
-- ------------------------------------------------------------
create table if not exists public.admin_audit_log (
  id         bigserial primary key,
  actor      uuid references auth.users(id) on delete set null,
  action     text        not null,
  target     text,
  details    jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_admin_audit_log_created on public.admin_audit_log(created_at desc);

alter table public.admin_audit_log enable row level security;
revoke all on table public.admin_audit_log from anon, authenticated, public;

create or replace function private.log_admin_action(p_action text, p_target text, p_details jsonb default null)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.admin_audit_log (actor, action, target, details)
  values (auth.uid(), p_action, p_target, p_details)
$$;

revoke all on function private.log_admin_action(text, text, jsonb) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 3. Usage events — one row per quiz start, guest or registered.
--    This is what the "registered vs. guest usage over time" dashboard
--    number is built from; nothing before this tracked guest play at all.
-- ------------------------------------------------------------
create table if not exists public.usage_events (
  id          bigserial primary key,
  event_type  text        not null,
  is_guest    boolean     not null,
  user_id     uuid references auth.users(id) on delete set null,
  occurred_at timestamptz not null default now()
);

create index if not exists idx_usage_events_occurred on public.usage_events(occurred_at);
create index if not exists idx_usage_events_type on public.usage_events(event_type, occurred_at);

alter table public.usage_events enable row level security;
revoke all on table public.usage_events from anon, authenticated, public;

create or replace function private.log_usage_event(p_event_type text, p_is_guest boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.usage_events (event_type, is_guest, user_id)
  values (p_event_type, p_is_guest, auth.uid())
$$;

revoke all on function private.log_usage_event(text, boolean) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 4. Settings — backed by the existing private.app_config table (01_schema),
--    which PostgREST can't reach at all since `private` isn't an exposed
--    schema. Admin RPCs are the only way in or out.
-- ------------------------------------------------------------
create or replace function private.setting_text(p_key text, p_default text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select value from private.app_config where key = p_key), p_default)
$$;

create or replace function private.setting_int(p_key text, p_default int)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select value::int from private.app_config where key = p_key), p_default)
$$;

revoke all on function private.setting_text(text, text) from public, anon, authenticated;
revoke all on function private.setting_int(text, int) from public, anon, authenticated;

-- Known, admin-tunable keys and their defaults. admin_set_setting() only
-- accepts keys from this list — there is no path from the admin UI to
-- writing an arbitrary key into private.app_config.
create table if not exists private.app_setting_defs (
  key         text primary key,
  default_val text not null,
  kind        text not null check (kind in ('int')),
  label       text not null
);
revoke all on table private.app_setting_defs from anon, authenticated, public;
alter table private.app_setting_defs enable row level security;

insert into private.app_setting_defs (key, default_val, kind, label) values
  ('rate_limit_get_quiz_questions_max',            '10',  'int', 'Quiz starts allowed per window (per account or IP)'),
  ('rate_limit_get_quiz_questions_window_minutes', '10',  'int', 'Quiz-start rate limit window, in minutes'),
  ('rate_limit_submit_answer_max',                 '200', 'int', 'Answers gradable per window (per account or IP)'),
  ('rate_limit_submit_answer_window_minutes',      '10',  'int', 'Answer-grading rate limit window, in minutes'),
  ('signup_ip_cap_per_day',                        '5',   'int', 'Max new accounts from one IP per 24h'),
  ('login_fail_min_seconds',                       '3',   'int', 'Minimum seconds between failed login attempts, per account')
on conflict (key) do nothing;

-- ------------------------------------------------------------
-- 5. Wire is_banned + configurable limits into the existing gameplay RPCs
--    (create-or-replace; none of these change signature).
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
  v_row         public.quiz_question_row;
  v_idx         int[];
  r             record;
begin
  if auth.uid() is not null and coalesce((select is_banned from public.profiles where id = auth.uid()), false) then
    raise exception 'account suspended' using errcode = '42501';
  end if;

  perform public.check_rate_limit(
    'get_quiz_questions',
    private.setting_int('rate_limit_get_quiz_questions_max', 10),
    make_interval(mins => private.setting_int('rate_limit_get_quiz_questions_window_minutes', 10))
  );

  if auth.uid() is null and not public.verify_turnstile(p_turnstile_token) then
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

  perform private.log_usage_event('quiz_start', auth.uid() is null);

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

create or replace function public.submit_quiz_answer(
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
  if v_uid is not null and coalesce((select is_banned from public.profiles where id = v_uid), false) then
    raise exception 'account suspended' using errcode = '42501';
  end if;

  perform public.check_rate_limit(
    'submit_quiz_answer',
    private.setting_int('rate_limit_submit_answer_max', 200),
    make_interval(mins => private.setting_int('rate_limit_submit_answer_window_minutes', 10))
  );

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

revoke all on function public.submit_quiz_answer(int, text, text, int, uuid) from public;
grant execute on function public.submit_quiz_answer(int, text, text, int, uuid) to anon, authenticated;

create or replace function public.start_quiz_session(
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
  if coalesce((select is_banned from public.profiles where id = v_uid), false) then
    raise exception 'account suspended' using errcode = '42501';
  end if;
  if p_language is null or p_language not in ('en','de','cs') then
    raise exception 'unsupported language' using errcode = '22023';
  end if;
  if p_domain_ids is null or coalesce(array_length(p_domain_ids, 1), 0) = 0 then
    raise exception 'at least one domain is required' using errcode = '22023';
  end if;

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

revoke all on function public.start_quiz_session(int[], text, int, int) from public;
grant execute on function public.start_quiz_session(int[], text, int, int) to authenticated;

create or replace function public.report_question(
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
  if coalesce((select is_banned from public.profiles where id = v_uid), false) then
    raise exception 'account suspended' using errcode = '42501';
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

revoke all on function public.report_question(int, text, text, uuid) from public;
grant execute on function public.report_question(int, text, text, uuid) to authenticated;

-- ------------------------------------------------------------
-- 6. hooks: pull their cap from settings instead of a hardcoded literal
-- ------------------------------------------------------------
create or replace function public.hook_restrict_signup_by_ip(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip    text := event -> 'metadata' ->> 'ip_address';
  v_count int;
  v_cap   int := private.setting_int('signup_ip_cap_per_day', 5);
begin
  if v_ip is null or v_ip = '' then
    return '{}'::jsonb;
  end if;

  if random() < 0.05 then
    delete from public.signup_ip_log where created_at < now() - interval '2 days';
  end if;

  select count(*) into v_count
    from public.signup_ip_log
   where ip_address = v_ip
     and created_at > now() - interval '24 hours';

  if v_count >= v_cap then
    return jsonb_build_object(
      'error', jsonb_build_object(
        'http_code', 429,
        'message', 'Too many accounts created from this network today. Please try again tomorrow.'
      )
    );
  end if;

  insert into public.signup_ip_log (ip_address) values (v_ip);
  return '{}'::jsonb;
end;
$$;

grant execute on function public.hook_restrict_signup_by_ip(jsonb) to supabase_auth_admin;
revoke execute on function public.hook_restrict_signup_by_ip(jsonb) from authenticated, anon, public;

create or replace function public.hook_password_verification_attempt(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (event ->> 'user_id')::uuid;
  v_last   timestamptz;
  v_min_gap interval := make_interval(secs => private.setting_int('login_fail_min_seconds', 3));
begin
  if (event ->> 'valid')::boolean is true then
    delete from public.password_failed_verification_attempts where user_id = v_uid;
    return jsonb_build_object('decision', 'continue');
  end if;

  select last_failed_at into v_last
    from public.password_failed_verification_attempts
   where user_id = v_uid;

  if v_last is not null and now() - v_last < v_min_gap then
    return jsonb_build_object(
      'error', jsonb_build_object(
        'http_code', 429,
        'message', 'Please wait a moment before trying again.'
      )
    );
  end if;

  insert into public.password_failed_verification_attempts (user_id, last_failed_at, fail_count)
  values (v_uid, now(), 1)
  on conflict (user_id) do update
    set last_failed_at = now(),
        fail_count     = public.password_failed_verification_attempts.fail_count + 1;

  return jsonb_build_object('decision', 'continue');
end;
$$;

grant execute on function public.hook_password_verification_attempt(jsonb) to supabase_auth_admin;
revoke execute on function public.hook_password_verification_attempt(jsonb) from authenticated, anon, public;

-- ------------------------------------------------------------
-- 7. admin_* RPCs
-- ------------------------------------------------------------

-- 7a. Users -----------------------------------------------------------
drop function if exists public.admin_list_users(text, int, int);
create or replace function public.admin_list_users(p_search text default null, p_limit int default 100, p_offset int default 0)
returns table (
  id uuid, email text, display_name text, is_admin boolean, is_banned boolean,
  created_at timestamptz, last_sign_in_at timestamptz,
  quizzes_played bigint, questions_answered bigint
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
    select p.id, u.email, p.display_name, p.is_admin, p.is_banned,
           p.created_at, u.last_sign_in_at,
           (select count(*) from public.quiz_sessions s where s.user_id = p.id) as quizzes_played,
           (select count(*) from public.quiz_answers qa
              join public.quiz_sessions s on s.id = qa.session_id
             where s.user_id = p.id) as questions_answered
    from public.profiles p
    join auth.users u on u.id = p.id
    where p_search is null or p_search = ''
       or u.email ilike '%' || p_search || '%'
       or p.display_name ilike '%' || p_search || '%'
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.admin_list_users(text, int, int) from public, anon, authenticated;
grant execute on function public.admin_list_users(text, int, int) to authenticated;

create or replace function public.admin_set_user_active(p_user_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() and p_active = false then
    raise exception 'cannot deactivate your own account' using errcode = '22023';
  end if;

  update public.profiles set is_banned = not p_active where id = p_user_id;
  perform private.log_admin_action(
    case when p_active then 'user_activate' else 'user_deactivate' end,
    p_user_id::text, null);
end;
$$;

revoke all on function public.admin_set_user_active(uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_user_active(uuid, boolean) to authenticated;

create or replace function public.admin_set_user_admin(p_user_id uuid, p_is_admin boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() and p_is_admin = false then
    raise exception 'cannot remove your own admin access — have another admin do it' using errcode = '22023';
  end if;

  update public.profiles set is_admin = p_is_admin where id = p_user_id;
  perform private.log_admin_action(
    case when p_is_admin then 'admin_grant' else 'admin_revoke' end,
    p_user_id::text, null);
end;
$$;

revoke all on function public.admin_set_user_admin(uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_user_admin(uuid, boolean) to authenticated;

-- 7b. Reported questions ------------------------------------------------
drop function if exists public.admin_list_reported_questions(boolean, int, int);
create or replace function public.admin_list_reported_questions(p_include_resolved boolean default false, p_limit int default 100, p_offset int default 0)
returns table (
  id uuid, question_id int, question_text text, reporter_email text,
  reason text, resolved boolean, created_at timestamptz
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
    select r.id, r.question_id, qt.text, u.email, r.reason, r.resolved, r.created_at
    from public.reported_questions r
    left join public.question_translations qt
      on qt.question_id = r.question_id and qt.language_code = 'en'
    left join auth.users u on u.id = r.user_id
    where p_include_resolved or not r.resolved
    order by r.created_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.admin_list_reported_questions(boolean, int, int) from public, anon, authenticated;
grant execute on function public.admin_list_reported_questions(boolean, int, int) to authenticated;

create or replace function public.admin_resolve_report(p_report_id uuid, p_resolved boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  update public.reported_questions set resolved = p_resolved where id = p_report_id;
  perform private.log_admin_action('report_resolve', p_report_id::text, jsonb_build_object('resolved', p_resolved));
end;
$$;

revoke all on function public.admin_resolve_report(uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_resolve_report(uuid, boolean) to authenticated;

-- 7c. Questions: browse, edit, single-toggle, CSV bulk import -----------
drop function if exists public.admin_list_questions(text, int, boolean, int, int);
create or replace function public.admin_list_questions(
  p_search    text    default null,
  p_domain_id int     default null,
  p_only_active boolean default null,
  p_limit     int     default 50,
  p_offset    int     default 0
)
returns table (
  id int, domain_id int, difficulty text, is_active boolean, correct_index int,
  text_en text, text_de text, text_cs text,
  options_en jsonb, options_de jsonb, options_cs jsonb
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
    select q.id, q.domain_id, q.difficulty, q.is_active, q.correct_index,
           en.text, de.text, cs.text,
           en.options, de.options, cs.options
    from public.questions q
    left join public.question_translations en on en.question_id = q.id and en.language_code = 'en'
    left join public.question_translations de on de.question_id = q.id and de.language_code = 'de'
    left join public.question_translations cs on cs.question_id = q.id and cs.language_code = 'cs'
    where (p_domain_id is null or q.domain_id = p_domain_id)
      and (p_only_active is null or q.is_active = p_only_active)
      and (p_search is null or p_search = '' or en.text ilike '%' || p_search || '%')
    order by q.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.admin_list_questions(text, int, boolean, int, int) from public, anon, authenticated;
grant execute on function public.admin_list_questions(text, int, boolean, int, int) to authenticated;

create or replace function public.admin_set_question_active(p_question_id int, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  update public.questions set is_active = p_active where id = p_question_id;
  perform private.log_admin_action(
    case when p_active then 'question_activate' else 'question_deactivate' end,
    p_question_id::text, null);
end;
$$;

revoke all on function public.admin_set_question_active(int, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_question_active(int, boolean) to authenticated;

create or replace function public.admin_update_question(
  p_question_id int,
  p_domain_id   int,
  p_difficulty  text,
  p_is_active   boolean,
  p_text_en     text,
  p_text_de     text,
  p_text_cs     text,
  p_options_en  jsonb,
  p_options_de  jsonb,
  p_options_cs  jsonb,
  p_correct_index int
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;
  if p_difficulty not in ('easy','medium','hard') then
    raise exception 'invalid difficulty' using errcode = '22023';
  end if;
  if jsonb_typeof(p_options_en) <> 'array' or jsonb_typeof(p_options_de) <> 'array' or jsonb_typeof(p_options_cs) <> 'array' then
    raise exception 'options must be arrays' using errcode = '22023';
  end if;
  if jsonb_array_length(p_options_en) <> jsonb_array_length(p_options_de)
     or jsonb_array_length(p_options_en) <> jsonb_array_length(p_options_cs) then
    raise exception 'option counts must match across languages' using errcode = '22023';
  end if;
  if jsonb_array_length(p_options_en) < 2 or jsonb_array_length(p_options_en) > 4 then
    raise exception 'need 2 to 4 options' using errcode = '22023';
  end if;
  if p_correct_index < 0 or p_correct_index >= jsonb_array_length(p_options_en) then
    raise exception 'correct index out of range' using errcode = '22023';
  end if;
  if not exists (select 1 from public.domains where id = p_domain_id) then
    raise exception 'unknown domain' using errcode = '22023';
  end if;

  update public.questions
     set domain_id = p_domain_id,
         difficulty = p_difficulty,
         is_active = p_is_active,
         correct_index = p_correct_index
   where id = p_question_id;

  insert into public.question_translations (question_id, language_code, text, options) values
    (p_question_id, 'en', p_text_en, p_options_en),
    (p_question_id, 'de', p_text_de, p_options_de),
    (p_question_id, 'cs', p_text_cs, p_options_cs)
  on conflict (question_id, language_code) do update
    set text = excluded.text, options = excluded.options;

  perform private.log_admin_action('question_update', p_question_id::text, null);
end;
$$;

revoke all on function public.admin_update_question(int, int, text, boolean, text, text, text, jsonb, jsonb, jsonb, int) from public, anon, authenticated;
grant execute on function public.admin_update_question(int, int, text, boolean, text, text, text, jsonb, jsonb, jsonb, int) to authenticated;

-- CSV bulk import. p_rows is a jsonb array of objects with the keys:
--   domain, difficulty, text_en, text_de, text_cs,
--   option1_en..option4_cs (option1/2 required, 3/4 optional), correct_option (1-based)
-- Matching for created/updated/duplicate is by normalized English question
-- text — the only stable, human-meaningful key a CSV of new questions has.
create or replace function public.admin_upsert_questions_csv(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row          jsonb;
  v_created      int := 0;
  v_updated      int := 0;
  v_duplicates   int := 0;
  v_invalid      int := 0;
  v_errors       jsonb := '[]'::jsonb;
  v_row_num      int := 0;

  v_domain_name  text;
  v_domain_id    int;
  v_difficulty   text;
  v_text_en      text;
  v_text_de      text;
  v_text_cs      text;
  v_opts_en      jsonb;
  v_opts_de      jsonb;
  v_opts_cs      jsonb;
  v_correct_opt  int;
  v_correct_opt_raw text;
  v_correct_idx  int;
  v_norm_text    text;
  v_existing_id  int;
  v_reason       text;
  i              int;
  v_slot_en      text;
  v_slot_de      text;
  v_slot_cs      text;
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a JSON array' using errcode = '22023';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_row_num := v_row_num + 1;
    v_reason := null;

    v_domain_name := btrim(coalesce(v_row ->> 'domain', ''));
    v_difficulty  := lower(btrim(coalesce(nullif(v_row ->> 'difficulty', ''), 'medium')));
    v_text_en     := btrim(coalesce(v_row ->> 'text_en', ''));
    v_text_de     := btrim(coalesce(v_row ->> 'text_de', ''));
    v_text_cs     := btrim(coalesce(v_row ->> 'text_cs', ''));

    v_opts_en := '[]'::jsonb; v_opts_de := '[]'::jsonb; v_opts_cs := '[]'::jsonb;
    for i in 1..4 loop
      v_slot_en := btrim(coalesce(v_row ->> ('option' || i || '_en'), ''));
      v_slot_de := btrim(coalesce(v_row ->> ('option' || i || '_de'), ''));
      v_slot_cs := btrim(coalesce(v_row ->> ('option' || i || '_cs'), ''));
      if v_slot_en <> '' or v_slot_de <> '' or v_slot_cs <> '' then
        if v_slot_en = '' or v_slot_de = '' or v_slot_cs = '' then
          v_reason := 'option ' || i || ' is missing a translation';
        else
          v_opts_en := v_opts_en || to_jsonb(v_slot_en);
          v_opts_de := v_opts_de || to_jsonb(v_slot_de);
          v_opts_cs := v_opts_cs || to_jsonb(v_slot_cs);
        end if;
      end if;
    end loop;

    if v_reason is null and v_domain_name = '' then v_reason := 'missing domain'; end if;
    if v_reason is null and (v_text_en = '' or v_text_de = '' or v_text_cs = '') then
      v_reason := 'missing question text in one or more languages';
    end if;
    if v_reason is null and v_difficulty not in ('easy','medium','hard') then
      v_reason := 'difficulty must be easy, medium or hard';
    end if;
    if v_reason is null and jsonb_array_length(v_opts_en) < 2 then
      v_reason := 'need at least 2 complete options';
    end if;
    if v_reason is null and (select count(*) from jsonb_array_elements_text(v_opts_en) o(v) where o.v <> '') <>
                             (select count(distinct o.v) from jsonb_array_elements_text(v_opts_en) o(v)) then
      v_reason := 'duplicate options in English column';
    end if;

    if v_reason is null then
      -- Validate the shape before casting: an uncaught cast error here would
      -- abort the whole batch, not just this row.
      v_correct_opt_raw := btrim(coalesce(v_row ->> 'correct_option', ''));
      if v_correct_opt_raw !~ '^[0-9]+$' then
        v_reason := 'correct_option must be a number';
      else
        v_correct_opt := v_correct_opt_raw::int;
        if v_correct_opt < 1 or v_correct_opt > jsonb_array_length(v_opts_en) then
          v_reason := 'correct_option must point at one of the provided options';
        else
          v_correct_idx := v_correct_opt - 1;
        end if;
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

    -- Everything up to here is pure validation with no writes. From here on
    -- a row could still fail a table CHECK constraint this function doesn't
    -- pre-validate (a future schema change, an edge case missed above) — an
    -- uncaught error inside a FOR loop would abort the whole batch, so wrap
    -- the write itself and downgrade any surprise into one invalid row.
    begin
      v_norm_text := regexp_replace(lower(v_text_en), '\s+', ' ', 'g');
      select q.id into v_existing_id
        from public.questions q
        join public.question_translations qt
          on qt.question_id = q.id and qt.language_code = 'en'
       where regexp_replace(lower(qt.text), '\s+', ' ', 'g') = v_norm_text
       limit 1;

      if v_existing_id is null then
        insert into public.questions (domain_id, correct_index, difficulty, is_active)
        values (v_domain_id, v_correct_idx, v_difficulty, true)
        returning id into v_existing_id;

        insert into public.question_translations (question_id, language_code, text, options) values
          (v_existing_id, 'en', v_text_en, v_opts_en),
          (v_existing_id, 'de', v_text_de, v_opts_de),
          (v_existing_id, 'cs', v_text_cs, v_opts_cs);

        v_created := v_created + 1;
      else
        if exists (
          select 1 from public.questions q
          where q.id = v_existing_id
            and q.domain_id = v_domain_id
            and q.difficulty = v_difficulty
            and q.correct_index = v_correct_idx
        ) and exists (
          select 1 from public.question_translations qt
           where qt.question_id = v_existing_id and qt.language_code = 'en' and qt.options = v_opts_en
        ) and exists (
          select 1 from public.question_translations qt
           where qt.question_id = v_existing_id and qt.language_code = 'de'
             and qt.text = v_text_de and qt.options = v_opts_de
        ) and exists (
          select 1 from public.question_translations qt
           where qt.question_id = v_existing_id and qt.language_code = 'cs'
             and qt.text = v_text_cs and qt.options = v_opts_cs
        ) then
          v_duplicates := v_duplicates + 1;
        else
          update public.questions
             set domain_id = v_domain_id, difficulty = v_difficulty, correct_index = v_correct_idx, is_active = true
           where id = v_existing_id;

          insert into public.question_translations (question_id, language_code, text, options) values
            (v_existing_id, 'en', v_text_en, v_opts_en),
            (v_existing_id, 'de', v_text_de, v_opts_de),
            (v_existing_id, 'cs', v_text_cs, v_opts_cs)
          on conflict (question_id, language_code) do update
            set text = excluded.text, options = excluded.options;

          v_updated := v_updated + 1;
        end if;
      end if;
    exception when others then
      v_invalid := v_invalid + 1;
      v_errors := v_errors || jsonb_build_object('row', v_row_num, 'reason', 'unexpected error: ' || sqlerrm);
    end;
  end loop;

  perform private.log_admin_action('questions_csv_import', null,
    jsonb_build_object('total', v_row_num, 'created', v_created, 'updated', v_updated,
                        'duplicates', v_duplicates, 'invalid', v_invalid));

  return jsonb_build_object(
    'total', v_row_num, 'created', v_created, 'updated', v_updated,
    'duplicates', v_duplicates, 'invalid', v_invalid, 'errors', v_errors
  );
end;
$$;

revoke all on function public.admin_upsert_questions_csv(jsonb) from public, anon, authenticated;
grant execute on function public.admin_upsert_questions_csv(jsonb) to authenticated;

-- 7d. Settings ------------------------------------------------------------
create or replace function public.admin_get_settings()
returns table (key text, value text, label text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  return query
    select d.key, coalesce(c.value, d.default_val), d.label
    from private.app_setting_defs d
    left join private.app_config c on c.key = d.key
    order by d.key;
end;
$$;

revoke all on function public.admin_get_settings() from public, anon, authenticated;
grant execute on function public.admin_get_settings() to authenticated;

create or replace function public.admin_set_setting(p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text;
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  select kind into v_kind from private.app_setting_defs where key = p_key;
  if v_kind is null then
    raise exception 'unknown setting key' using errcode = '22023';
  end if;
  if v_kind = 'int' and p_value !~ '^[0-9]+$' then
    raise exception 'value must be a non-negative integer' using errcode = '22023';
  end if;

  insert into private.app_config (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;

  perform private.log_admin_action('setting_change', p_key, jsonb_build_object('value', p_value));
end;
$$;

revoke all on function public.admin_set_setting(text, text) from public, anon, authenticated;
grant execute on function public.admin_set_setting(text, text) to authenticated;

-- 7e. Audit log read + usage dashboard ------------------------------------
create or replace function public.admin_list_audit_log(p_limit int default 100, p_offset int default 0)
returns table (id bigint, actor_email text, action text, target text, details jsonb, created_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  return query
    select a.id, u.email, a.action, a.target, a.details, a.created_at
    from public.admin_audit_log a
    left join auth.users u on u.id = a.actor
    order by a.created_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.admin_list_audit_log(int, int) from public, anon, authenticated;
grant execute on function public.admin_list_audit_log(int, int) to authenticated;

create or replace function public.admin_usage_stats(p_days int default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 30), 1), 365);
  v_daily jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(t) order by t.day), '[]'::jsonb) into v_daily
  from (
    select d::date as day,
           count(*) filter (where e.is_guest)     as guest_quizzes,
           count(*) filter (where not e.is_guest) as registered_quizzes
    from generate_series(current_date - (v_days - 1), current_date, interval '1 day') d
    left join public.usage_events e
      on e.event_type = 'quiz_start'
     and e.occurred_at::date = d::date
    group by d
  ) t;

  return jsonb_build_object(
    'daily', v_daily,
    'total_users', (select count(*) from public.profiles),
    'total_admins', (select count(*) from public.profiles where is_admin),
    'total_banned', (select count(*) from public.profiles where is_banned),
    'total_questions', (select count(*) from public.questions where is_active),
    'open_reports', (select count(*) from public.reported_questions where not resolved)
  );
end;
$$;

revoke all on function public.admin_usage_stats(int) from public, anon, authenticated;
grant execute on function public.admin_usage_stats(int) to authenticated;

-- ------------------------------------------------------------
-- 8. Default privileges
-- ------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
