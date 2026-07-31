-- ============================================================
-- Sharpet — 06_hardening.sql
-- Turnstile captcha verification, RPC rate limiting, and per-IP /
-- per-account abuse throttles on top of Auth. Idempotent: safe to re-run.
--
-- What this closes, from SECURITY.md "Known limitations":
--   * The old client-side arithmetic captcha (assets/app.js) is gone. Guests
--     starting a quiz now solve a Cloudflare Turnstile widget, and the token
--     is verified *inside Postgres* (verify_turnstile) before any questions
--     are handed out — a client can no longer skip the check by reading the
--     JS bundle for the answer.
--   * get_quiz_questions() and submit_quiz_answer() had no rate limit at
--     all. Both are now capped per caller (per-account when logged in,
--     per-IP for guests), which is what actually stops the "20000 RPC calls
--     to brute-force the answer key" scenario the old doc flagged as open.
--   * Two Auth Hooks (wired by hand in the dashboard — see SECURITY.md) add
--     IP-based signup throttling and per-account failed-login throttling,
--     on top of Supabase's own built-in Auth rate limits.
--
-- This file assumes 01–05 have already been applied.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Extensions
--    `http` gives a synchronous HTTP call from inside a function, which is
--    what lets verify_turnstile() block on Cloudflare's answer instead of
--    firing an async request and hoping. Supabase ships it as a trusted
--    extension; no superuser needed.
-- ------------------------------------------------------------
create extension if not exists http with schema extensions;

-- ------------------------------------------------------------
-- 1. Client IP helper
--    PostgREST puts the request headers, including the edge-set
--    X-Forwarded-For, into the `request.headers` GUC as JSON. This is the
--    only notion of "caller identity" available for anonymous callers.
-- ------------------------------------------------------------
create or replace function public.client_ip()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(
    split_part(
      coalesce((current_setting('request.headers', true)::json ->> 'x-forwarded-for'), ''),
      ',', 1
    ),
    ''
  )
$$;

revoke all on function public.client_ip() from public, anon, authenticated;

-- ------------------------------------------------------------
-- 2. Generic RPC rate limiter
--    Keyed by account when logged in, by IP otherwise. RLS with no
--    policies means clients can't read or write this table directly at
--    all — only the SECURITY DEFINER functions below (running as owner)
--    can touch it.
-- ------------------------------------------------------------
create table if not exists public.rpc_rate_limits (
  id        bigserial primary key,
  bucket    text        not null,
  rate_key  text        not null,
  called_at timestamptz not null default now()
);

create index if not exists rpc_rate_limits_lookup
  on public.rpc_rate_limits (bucket, rate_key, called_at);

alter table public.rpc_rate_limits enable row level security;
revoke all on table public.rpc_rate_limits from anon, authenticated, public;

create or replace function public.check_rate_limit(p_bucket text, p_max int, p_window interval)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key   text := coalesce(auth.uid()::text, public.client_ip(), 'unknown');
  v_count int;
begin
  -- Opportunistic cleanup instead of a scheduled job: cheap, and there's no
  -- pg_cron guarantee on every Supabase plan.
  if random() < 0.01 then
    delete from public.rpc_rate_limits where called_at < now() - interval '1 day';
  end if;

  select count(*) into v_count
    from public.rpc_rate_limits
   where bucket = p_bucket
     and rate_key = v_key
     and called_at > now() - p_window;

  if v_count >= p_max then
    raise exception 'rate limit exceeded' using errcode = '53400';
  end if;

  insert into public.rpc_rate_limits (bucket, rate_key) values (p_bucket, v_key);
end;
$$;

revoke all on function public.check_rate_limit(text, int, interval) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 3. Turnstile verification
--    The secret key lives in Supabase Vault, never in a table anon/
--    authenticated can read and never in this repo. Create it once from
--    the SQL editor:
--      select vault.create_secret('<your-secret-key>', 'turnstile_secret_key');
--    Until that secret exists, verify_turnstile() fails closed (returns
--    false) rather than silently letting guests through.
-- ------------------------------------------------------------
create or replace function public.verify_turnstile(p_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret   text;
  v_response extensions.http_response;
  v_body     jsonb;
begin
  if p_token is null or length(p_token) = 0 then
    return false;
  end if;

  select decrypted_secret into v_secret
    from vault.decrypted_secrets
   where name = 'turnstile_secret_key';

  if v_secret is null then
    raise warning 'turnstile_secret_key not set in Vault; rejecting captcha verification';
    return false;
  end if;

  select * into v_response
    from extensions.http_post(
      'https://challenges.cloudflare.com/turnstile/v0/siteverify',
      -- jsonb_strip_nulls: client_ip() can legitimately be null (header
      -- missing), and Cloudflare treats remoteip as optional but expects it
      -- absent, not present-and-null.
      jsonb_strip_nulls(jsonb_build_object(
        'secret', v_secret,
        'response', p_token,
        'remoteip', public.client_ip()
      ))::text,
      'application/json'
    );

  if v_response.status <> 200 then
    return false;
  end if;

  v_body := v_response.content::jsonb;
  return coalesce((v_body ->> 'success')::boolean, false);
exception when others then
  raise warning 'turnstile verification errored: %', sqlerrm;
  return false;
end;
$$;

revoke all on function public.verify_turnstile(text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 4. get_quiz_questions — add rate limiting + Turnstile for guests
--    Signature gains p_turnstile_token. The old 4-arg version is dropped
--    first — a bare CREATE OR REPLACE can't change a function's arity, it
--    would just add a second, unguarded overload that anon could still
--    call directly. The DROP only matters on the very first run of this
--    file; CREATE OR REPLACE after that keeps re-runs idempotent.
-- ------------------------------------------------------------
drop function if exists public.get_quiz_questions(int[], text, int, int);

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
  -- 10 batches per 10 minutes, per account or per IP. A real person does not
  -- start 10 quizzes in 10 minutes; a scraper harvesting the question bank
  -- does. This is the actual fix for the "20000 RPC calls" brute-force path
  -- noted in SECURITY.md — previously nothing capped this call at all.
  perform public.check_rate_limit('get_quiz_questions', 10, interval '10 minutes');

  -- Only guests need to clear a captcha: a logged-in caller is already
  -- accountable (rate-limited by account, revocable, bound to a real
  -- e-mail), so gating them too would just be friction with no new control.
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

-- ------------------------------------------------------------
-- 5. submit_quiz_answer — add rate limiting
--    Signature is unchanged, so this is a straight create-or-replace.
--    200 gradings per 10 minutes is roughly two full 100-question quizzes
--    back to back — generous for a fast human, a real ceiling for a script
--    trying to clear the answer key by brute force.
-- ------------------------------------------------------------
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
  perform public.check_rate_limit('submit_quiz_answer', 200, interval '10 minutes');

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

-- ------------------------------------------------------------
-- 6. Auth Hook: before-user-created — per-IP signup throttle
--    Supabase's own built-in signup rate limit is IP-based too, but it's
--    tied to the e-mail-sending quota (2/hour on the built-in mailer,
--    30/hour on custom SMTP) and project-wide rather than per-IP in the
--    "one address, five accounts" sense. This adds a per-IP daily cap
--    independent of that.
--
--    Must be wired by hand: Dashboard → Authentication → Auth Hooks →
--    "Before User Created" → Postgres function →
--    public.hook_restrict_signup_by_ip. SQL alone cannot enable a hook.
-- ------------------------------------------------------------
create table if not exists public.signup_ip_log (
  id         bigserial primary key,
  ip_address text        not null,
  created_at timestamptz not null default now()
);

create index if not exists signup_ip_log_lookup on public.signup_ip_log (ip_address, created_at);

alter table public.signup_ip_log enable row level security;
revoke all on table public.signup_ip_log from anon, authenticated, public;

create or replace function public.hook_restrict_signup_by_ip(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip    text := event -> 'metadata' ->> 'ip_address';
  v_count int;
begin
  if v_ip is null or v_ip = '' then
    -- No IP on the payload (shouldn't happen, but don't lock signups over it).
    return '{}'::jsonb;
  end if;

  if random() < 0.05 then
    delete from public.signup_ip_log where created_at < now() - interval '2 days';
  end if;

  select count(*) into v_count
    from public.signup_ip_log
   where ip_address = v_ip
     and created_at > now() - interval '24 hours';

  if v_count >= 5 then
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

-- ------------------------------------------------------------
-- 7. Auth Hook: password-verification-attempt — per-account login throttle
--    This hook's payload carries user_id + whether the attempt was valid,
--    not an IP — so it complements, rather than replaces, Supabase's
--    built-in IP-based token-bucket limit on /auth/v1/token. It stops fast
--    password-guessing against one known account regardless of how many
--    IPs the attacker spreads the attempts across.
--
--    Must also be wired by hand: Dashboard → Authentication → Auth Hooks →
--    "Password Verification Attempt" → Postgres function →
--    public.hook_password_verification_attempt.
-- ------------------------------------------------------------
create table if not exists public.password_failed_verification_attempts (
  user_id        uuid primary key,
  last_failed_at timestamptz not null default now(),
  fail_count     int         not null default 0
);

alter table public.password_failed_verification_attempts enable row level security;
revoke all on table public.password_failed_verification_attempts from anon, authenticated, public;

create or replace function public.hook_password_verification_attempt(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (event ->> 'user_id')::uuid;
  v_last timestamptz;
begin
  if (event ->> 'valid')::boolean is true then
    delete from public.password_failed_verification_attempts where user_id = v_uid;
    return jsonb_build_object('decision', 'continue');
  end if;

  select last_failed_at into v_last
    from public.password_failed_verification_attempts
   where user_id = v_uid;

  if v_last is not null and now() - v_last < interval '3 seconds' then
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
-- 8. Default privileges — keep new tables/functions closed by default
-- ------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
