-- ============================================================
-- Sharpet — 09_region_block.sql
-- Guest-only region blocking (Asia / Africa / South America, by default)
-- and a fixed demo pool of questions for unregistered play. Idempotent:
-- safe to re-run.
--
-- Scope, deliberately: this only ever applies when auth.uid() is null.
-- An existing registered user keeps playing normally regardless of where
-- they're connecting from — only guests (and, best-effort, new sign-ups —
-- see the note below) are affected. That's a product decision, not a
-- technical limitation: the check is written as
-- `auth.uid() is null and public.is_region_blocked()` at every call site,
-- so it's one condition away from being changed if that decision changes.
--
-- Known limitation: sign-up requests reach Postgres through the
-- before-user-created Auth Hook, a different code path than PostgREST,
-- which does not carry Cloudflare's cf-ipcountry header — only a raw IP
-- (see hook_restrict_signup_by_ip in 07_admin.sql). Resolving a country
-- from that IP without an external API call would need a full local
-- IP-range-to-country database (e.g. MaxMind GeoLite2), which isn't wired
-- up here. Practically this doesn't matter much: a blocked-region visitor
-- can still create an account, but can never play a quiz with it, guest or
-- logged in as that brand-new account — see the "new account" carve-out
-- below.
--
-- This file assumes 01–08 have already been applied.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Country → continent lookup
--    ISO 3166-1 alpha-2 codes. A handful of transcontinental countries
--    (Russia, Turkey, Georgia, Armenia, Azerbaijan, Kazakhstan, Cyprus) are
--    assigned by common convention, not physical geography — edit this
--    table directly if a specific assignment matters to you.
-- ------------------------------------------------------------
create table if not exists private.country_continent (
  country_code text primary key,
  continent    text not null
);
revoke all on table private.country_continent from anon, authenticated, public;
alter table private.country_continent enable row level security;

insert into private.country_continent (country_code, continent) values
  -- Africa
  ('DZ','Africa'),('AO','Africa'),('BJ','Africa'),('BW','Africa'),('BF','Africa'),
  ('BI','Africa'),('CV','Africa'),('CM','Africa'),('CF','Africa'),('TD','Africa'),
  ('KM','Africa'),('CG','Africa'),('CD','Africa'),('CI','Africa'),('DJ','Africa'),
  ('EG','Africa'),('GQ','Africa'),('ER','Africa'),('SZ','Africa'),('ET','Africa'),
  ('GA','Africa'),('GM','Africa'),('GH','Africa'),('GN','Africa'),('GW','Africa'),
  ('KE','Africa'),('LS','Africa'),('LR','Africa'),('LY','Africa'),('MG','Africa'),
  ('MW','Africa'),('ML','Africa'),('MR','Africa'),('MU','Africa'),('YT','Africa'),
  ('MA','Africa'),('MZ','Africa'),('NA','Africa'),('NE','Africa'),('NG','Africa'),
  ('RE','Africa'),('RW','Africa'),('SH','Africa'),('ST','Africa'),('SN','Africa'),
  ('SC','Africa'),('SL','Africa'),('SO','Africa'),('ZA','Africa'),('SS','Africa'),
  ('SD','Africa'),('TZ','Africa'),('TG','Africa'),('TN','Africa'),('UG','Africa'),
  ('EH','Africa'),('ZM','Africa'),('ZW','Africa'),
  -- Asia
  ('AF','Asia'),('AM','Asia'),('AZ','Asia'),('BH','Asia'),('BD','Asia'),
  ('BT','Asia'),('BN','Asia'),('KH','Asia'),('CN','Asia'),('GE','Asia'),
  ('HK','Asia'),('IN','Asia'),('ID','Asia'),('IR','Asia'),('IQ','Asia'),
  ('IL','Asia'),('JP','Asia'),('JO','Asia'),('KZ','Asia'),('KP','Asia'),
  ('KR','Asia'),('KW','Asia'),('KG','Asia'),('LA','Asia'),('LB','Asia'),
  ('MO','Asia'),('MY','Asia'),('MV','Asia'),('MN','Asia'),('MM','Asia'),
  ('NP','Asia'),('OM','Asia'),('PK','Asia'),('PS','Asia'),('PH','Asia'),
  ('QA','Asia'),('SA','Asia'),('SG','Asia'),('LK','Asia'),('SY','Asia'),
  ('TW','Asia'),('TJ','Asia'),('TH','Asia'),('TL','Asia'),('TR','Asia'),
  ('TM','Asia'),('AE','Asia'),('UZ','Asia'),('VN','Asia'),('YE','Asia'),
  -- Europe
  ('AL','Europe'),('AD','Europe'),('AT','Europe'),('BY','Europe'),('BE','Europe'),
  ('BA','Europe'),('BG','Europe'),('HR','Europe'),('CY','Europe'),('CZ','Europe'),
  ('DK','Europe'),('EE','Europe'),('FO','Europe'),('FI','Europe'),('FR','Europe'),
  ('DE','Europe'),('GI','Europe'),('GR','Europe'),('GG','Europe'),('VA','Europe'),
  ('HU','Europe'),('IS','Europe'),('IE','Europe'),('IM','Europe'),('IT','Europe'),
  ('JE','Europe'),('XK','Europe'),('LV','Europe'),('LI','Europe'),('LT','Europe'),
  ('LU','Europe'),('MT','Europe'),('MD','Europe'),('MC','Europe'),('ME','Europe'),
  ('NL','Europe'),('MK','Europe'),('NO','Europe'),('PL','Europe'),('PT','Europe'),
  ('RO','Europe'),('RU','Europe'),('SM','Europe'),('RS','Europe'),('SK','Europe'),
  ('SI','Europe'),('ES','Europe'),('SJ','Europe'),('SE','Europe'),('CH','Europe'),
  ('UA','Europe'),('GB','Europe'),('AX','Europe'),
  -- North America
  ('AI','North America'),('AG','North America'),('AW','North America'),('BS','North America'),
  ('BB','North America'),('BZ','North America'),('BM','North America'),('BQ','North America'),
  ('VG','North America'),('CA','North America'),('KY','North America'),('CR','North America'),
  ('CU','North America'),('CW','North America'),('DM','North America'),('DO','North America'),
  ('SV','North America'),('GL','North America'),('GD','North America'),('GP','North America'),
  ('GT','North America'),('HT','North America'),('HN','North America'),('JM','North America'),
  ('MQ','North America'),('MX','North America'),('MS','North America'),('NI','North America'),
  ('PA','North America'),('PR','North America'),('BL','North America'),('KN','North America'),
  ('LC','North America'),('MF','North America'),('PM','North America'),('VC','North America'),
  ('SX','North America'),('TT','North America'),('TC','North America'),('US','North America'),
  ('VI','North America'),
  -- Oceania
  ('AS','Oceania'),('AU','Oceania'),('CK','Oceania'),('FJ','Oceania'),('PF','Oceania'),
  ('GU','Oceania'),('KI','Oceania'),('MH','Oceania'),('FM','Oceania'),('NR','Oceania'),
  ('NC','Oceania'),('NZ','Oceania'),('NU','Oceania'),('NF','Oceania'),('MP','Oceania'),
  ('PW','Oceania'),('PG','Oceania'),('PN','Oceania'),('WS','Oceania'),('SB','Oceania'),
  ('TK','Oceania'),('TO','Oceania'),('TV','Oceania'),('VU','Oceania'),('WF','Oceania'),
  -- South America
  ('AR','South America'),('BO','South America'),('BR','South America'),('CL','South America'),
  ('CO','South America'),('EC','South America'),('FK','South America'),('GF','South America'),
  ('GY','South America'),('PY','South America'),('PE','South America'),('SR','South America'),
  ('UY','South America'),('VE','South America'),('GS','South America'),
  -- Antarctica
  ('AQ','Antarctica'),('TF','Antarctica'),('BV','Antarctica'),('HM','Antarctica')
on conflict (country_code) do update set continent = excluded.continent;

-- ------------------------------------------------------------
-- 2. Manual IP/CIDR ban list — separate from, and in addition to, the
--    continent rule. A bare IP (e.g. '203.0.113.7') casts to a /32 (or
--    /128 for IPv6), i.e. a single-address ban.
-- ------------------------------------------------------------
create table if not exists public.ip_bans (
  id         bigserial primary key,
  cidr       cidr not null unique,
  reason     text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

do $$ begin
  alter table public.ip_bans
    add constraint ip_bans_reason_len check (reason is null or char_length(reason) <= 300);
exception when duplicate_object then null; end $$;

alter table public.ip_bans enable row level security;
revoke all on table public.ip_bans from anon, authenticated, public;

-- ------------------------------------------------------------
-- 3. blocked_continents setting — reuses the private.app_config /
--    app_setting_defs pattern from 07_admin.sql, extended with a 'text'
--    kind (the existing defs were all 'int').
-- ------------------------------------------------------------
alter table private.app_setting_defs drop constraint if exists app_setting_defs_kind_check;
do $$ begin
  alter table private.app_setting_defs add constraint app_setting_defs_kind_check check (kind in ('int','text'));
exception when duplicate_object then null; end $$;

insert into private.app_setting_defs (key, default_val, kind, label) values
  ('blocked_continents', 'Asia,Africa,South America', 'text',
   'Comma-separated continents blocked from guest play and signup (Africa, Antarctica, Asia, Europe, North America, Oceania, South America)')
on conflict (key) do nothing;

-- admin_set_setting (07_admin.sql) only validated 'int' kind — replace it
-- so a 'text' setting can be saved too.
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
  if v_kind = 'text' and length(btrim(coalesce(p_value, ''))) = 0 then
    raise exception 'value cannot be empty' using errcode = '22023';
  end if;

  insert into private.app_config (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;

  perform private.log_admin_action('setting_change', p_key, jsonb_build_object('value', p_value));
end;
$$;

revoke all on function public.admin_set_setting(text, text) from public, anon, authenticated;
grant execute on function public.admin_set_setting(text, text) to authenticated;

-- ------------------------------------------------------------
-- 4. is_region_blocked() — continent rule OR a manual CIDR ban.
--    Unknown country (no cf-ipcountry header — e.g. a request that somehow
--    didn't come through Cloudflare) fails OPEN, not closed: this blocks
--    specific regions, it is not meant to lock out everyone the moment the
--    header is ever missing.
-- ------------------------------------------------------------
create or replace function public.is_region_blocked()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_country    text := public.client_country();
  v_ip         text := public.client_ip();
  v_continent  text;
  v_blocked    text[];
begin
  if v_country is not null then
    select continent into v_continent from private.country_continent where country_code = v_country;
    if v_continent is not null then
      select string_to_array(private.setting_text('blocked_continents', 'Asia,Africa,South America'), ',')
        into v_blocked;
      if v_continent = any (v_blocked) then
        return true;
      end if;
    end if;
  end if;

  if v_ip is not null and exists (
    select 1 from public.ip_bans b where v_ip::inet <<= b.cidr
  ) then
    return true;
  end if;

  return false;
exception when others then
  -- A malformed/unparseable IP must never turn into a hard error for every
  -- guest request — treat it the same as "unknown", i.e. not blocked. Still
  -- surface a warning so a real bug here doesn't go completely unnoticed.
  raise warning 'is_region_blocked() errored, defaulting to not-blocked: %', sqlerrm;
  return false;
end;
$$;

revoke all on function public.is_region_blocked() from public, anon, authenticated;

-- Thin public wrapper so the frontend can proactively grey out the Play /
-- Log in buttons instead of only finding out after a click — a UX nicety,
-- not the control. The control is is_region_blocked() being checked inside
-- get_quiz_questions/submit_quiz_answer regardless of what this returns or
-- whether the frontend even calls it. Mirrors the guest-only scope of that
-- check: an already-logged-in caller always gets false here, same as they
-- always skip the block in the gameplay RPCs.
create or replace function public.region_status()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is null and public.is_region_blocked()
$$;

revoke all on function public.region_status() from public;
grant execute on function public.region_status() to anon, authenticated;

-- ------------------------------------------------------------
-- 5. Guest demo pool: unregistered play only ever draws from a fixed,
--    curated set of questions, not the full active bank.
-- ------------------------------------------------------------
alter table public.questions add column if not exists is_guest_demo boolean not null default false;
create index if not exists idx_questions_guest_demo on public.questions(is_guest_demo) where is_guest_demo;

-- Seed at least 10 guest-demo questions per domain, picked at random rather
-- than "the first 10 by id" (which would show every guest the exact same
-- set every time). A guest choosing a single domain still gets a real pool
-- to draw from, not a handful of repeats.
--
-- This is a per-domain top-up, not a one-shot seed: a domain that already
-- has >= 10 flagged rows is left untouched, so an admin's later curation via
-- the question editor's "Guest demo pool" checkbox is never overwritten or
-- reduced. That also makes it safe — and necessary — to re-run this block
-- after seeding new questions (e.g. a fresh db/03_seed_questions load), so
-- newly added questions are picked up for any domain that was still short.
do $$
declare
  d      record;
  needed int;
begin
  for d in select id from public.domains loop
    select count(*) into needed
      from public.questions
     where domain_id = d.id and is_active and is_guest_demo;
    needed := 10 - needed;
    if needed > 0 then
      update public.questions
         set is_guest_demo = true
       where id in (
         select id from public.questions
          where domain_id = d.id and is_active and not is_guest_demo
          order by random()
          limit needed
       );
    end if;
  end loop;
end $$;

-- ------------------------------------------------------------
-- 6. Wire both checks into the gameplay RPCs. Signatures unchanged.
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
  v_is_guest       boolean := v_uid is null;
  v_correct_index  int;
  v_domain_id      int;
  v_options        jsonb;
  v_result         public.quiz_answer_result;
begin
  if not v_is_guest and coalesce((select is_banned from public.profiles where id = v_uid), false) then
    raise exception 'account suspended' using errcode = '42501';
  end if;

  if v_is_guest and public.is_region_blocked() then
    raise exception 'this feature is not available in your region' using errcode = '42501';
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
    and q.is_active
    and (not v_is_guest or q.is_guest_demo);

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
-- 7. admin_* RPCs for the ban list and question-bank list/edit updates
--    (list/update gain the is_guest_demo column; same signatures otherwise
--    would break the frontend, so this is a new overload situation for
--    admin_update_question — dropped and recreated, same reasoning as
--    get_quiz_questions in 06_hardening.sql).
-- ------------------------------------------------------------
create or replace function public.admin_list_ip_bans()
returns table (id bigint, cidr text, reason text, created_by_email text, created_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  return query
    select b.id, b.cidr::text, b.reason, u.email::text, b.created_at
    from public.ip_bans b
    left join auth.users u on u.id = b.created_by
    order by b.created_at desc;
end;
$$;

revoke all on function public.admin_list_ip_bans() from public, anon, authenticated;
grant execute on function public.admin_list_ip_bans() to authenticated;

create or replace function public.admin_add_ip_ban(p_cidr text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cidr cidr;
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  begin
    v_cidr := p_cidr::cidr;
  exception when others then
    raise exception 'not a valid IP address or CIDR range' using errcode = '22023';
  end;

  insert into public.ip_bans (cidr, reason, created_by)
  values (v_cidr, left(regexp_replace(coalesce(p_reason, ''), '[[:cntrl:]]', '', 'g'), 300), auth.uid())
  on conflict (cidr) do update set reason = excluded.reason;

  perform private.log_admin_action('ip_ban_add', v_cidr::text, jsonb_build_object('reason', p_reason));
end;
$$;

revoke all on function public.admin_add_ip_ban(text, text) from public, anon, authenticated;
grant execute on function public.admin_add_ip_ban(text, text) to authenticated;

create or replace function public.admin_remove_ip_ban(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cidr text;
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  select cidr::text into v_cidr from public.ip_bans where id = p_id;
  delete from public.ip_bans where id = p_id;
  perform private.log_admin_action('ip_ban_remove', v_cidr, null);
end;
$$;

revoke all on function public.admin_remove_ip_ban(bigint) from public, anon, authenticated;
grant execute on function public.admin_remove_ip_ban(bigint) to authenticated;

drop function if exists public.admin_list_questions(text, int, boolean, int, int);
create or replace function public.admin_list_questions(
  p_search    text    default null,
  p_domain_id int     default null,
  p_only_active boolean default null,
  p_limit     int     default 50,
  p_offset    int     default 0
)
returns table (
  id int, domain_id int, difficulty text, is_active boolean, is_guest_demo boolean, correct_index int,
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
    select q.id, q.domain_id, q.difficulty, q.is_active, q.is_guest_demo, q.correct_index,
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

drop function if exists public.admin_update_question(int, int, text, boolean, text, text, text, jsonb, jsonb, jsonb, int);
create or replace function public.admin_update_question(
  p_question_id   int,
  p_domain_id     int,
  p_difficulty    text,
  p_is_active     boolean,
  p_text_en       text,
  p_text_de       text,
  p_text_cs       text,
  p_options_en    jsonb,
  p_options_de    jsonb,
  p_options_cs    jsonb,
  p_correct_index int,
  p_is_guest_demo boolean default false
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
         is_guest_demo = coalesce(p_is_guest_demo, false),
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

revoke all on function public.admin_update_question(int, int, text, boolean, text, text, text, jsonb, jsonb, jsonb, int, boolean) from public, anon, authenticated;
grant execute on function public.admin_update_question(int, int, text, boolean, text, text, text, jsonb, jsonb, jsonb, int, boolean) to authenticated;

-- ------------------------------------------------------------
-- 8. Default privileges
-- ------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
