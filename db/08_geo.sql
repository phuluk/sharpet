-- ============================================================
-- Sharpet — 08_geo.sql
-- Country-of-origin tracking for the usage dashboard, sourced from
-- Cloudflare's cf-ipcountry header rather than a third-party geo-IP
-- lookup — Supabase's API already sits behind Cloudflare, so this is a
-- header PostgREST already receives on every request. No visitor IP is
-- ever sent anywhere outside this project to get it.
--
-- This file assumes 01–07 have already been applied.
-- ============================================================

-- ------------------------------------------------------------
-- 1. client_country() — same pattern as client_ip() in 06_hardening.sql
--    cf-ipcountry is a two-letter ISO 3166-1 alpha-2 code, or "XX" /"T1"
--    for cases Cloudflare itself can't resolve (Tor, unknown). Treat
--    anything that isn't two letters as unknown rather than trusting it
--    blindly — this value came from a request header, not a database.
-- ------------------------------------------------------------
create or replace function public.client_country()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(upper(coalesce((current_setting('request.headers', true)::json ->> 'cf-ipcountry'), '')), '')
$$;

revoke all on function public.client_country() from public, anon, authenticated;

-- ------------------------------------------------------------
-- 2. usage_events gets a country column
-- ------------------------------------------------------------
alter table public.usage_events add column if not exists country text;

do $$ begin
  alter table public.usage_events
    add constraint usage_events_country_format check (country is null or country ~ '^[A-Z0-9]{2}$');
exception when duplicate_object then null; end $$;

create index if not exists idx_usage_events_country on public.usage_events(country);

-- log_usage_event now stamps the country itself rather than taking it as a
-- parameter, so the one call site in get_quiz_questions doesn't need to
-- change — same reasoning as why it already reads auth.uid() internally
-- instead of being passed a uid.
create or replace function private.log_usage_event(p_event_type text, p_is_guest boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.usage_events (event_type, is_guest, user_id, country)
  values (p_event_type, p_is_guest, auth.uid(), public.client_country())
$$;

revoke all on function private.log_usage_event(text, boolean) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 3. admin_usage_stats: add a by-country breakdown alongside the existing
--    daily guest/registered numbers. Unknown-country rows (older data from
--    before this migration, or a request Cloudflare couldn't place) are
--    grouped under "??" rather than dropped.
-- ------------------------------------------------------------
create or replace function public.admin_usage_stats(p_days int default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 30), 1), 365);
  v_daily jsonb;
  v_by_country jsonb;
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

  select coalesce(jsonb_agg(to_jsonb(t) order by t.quizzes desc), '[]'::jsonb) into v_by_country
  from (
    select coalesce(e.country, '??') as country, count(*) as quizzes
    from public.usage_events e
    where e.event_type = 'quiz_start'
      and e.occurred_at >= now() - make_interval(days => v_days)
    group by coalesce(e.country, '??')
    order by count(*) desc
    limit 25
  ) t;

  return jsonb_build_object(
    'daily', v_daily,
    'by_country', v_by_country,
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

alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
