-- ============================================================
-- Sharpet — 04_security.sql
-- Row Level Security, column privileges, auth trigger.
-- Idempotent: safe to re-run.
--
-- Security model
-- --------------
--  * questions.correct_index is NEVER readable by a client (column-level
--    revoke). Gameplay goes through the RPCs in 05_rpc.sql, which grade
--    answers server-side.
--  * quiz_sessions / quiz_answers / reported_questions are READ-ONLY for
--    clients. All writes go through SECURITY DEFINER functions that stamp
--    auth.uid() themselves, so a client cannot forge another user's rows or
--    invent its own score.
--  * profiles are visible to the owner and to accepted friends only — not to
--    the whole internet. (Display names are derived from e-mail local parts,
--    so a public profiles table leaked partial addresses of every user.)
-- ============================================================

-- ------------------------------------------------------------
-- 1. Enable RLS everywhere
-- ------------------------------------------------------------
alter table public.domains               enable row level security;
alter table public.domain_translations   enable row level security;
alter table public.questions             enable row level security;
alter table public.question_translations enable row level security;
alter table public.profiles              enable row level security;
alter table public.quiz_sessions         enable row level security;
alter table public.quiz_answers          enable row level security;
alter table public.reported_questions    enable row level security;
alter table public.friendships           enable row level security;

-- Deliberately NOT using `force row level security` on the write-protected
-- tables. The SECURITY DEFINER functions in 05_rpc.sql run as the table owner
-- and rely on the owner's normal RLS exemption to insert; forcing RLS would
-- break every write unless we added permissive insert policies, which is
-- exactly what routing writes through those functions is meant to avoid.
-- Clients never connect as the owner, so there is nothing to force.

-- Undo the blanket grants Supabase hands to anon/authenticated. Everything
-- below is then granted back explicitly, column by column where it matters.
revoke all on all tables in schema public from anon, authenticated;

-- ------------------------------------------------------------
-- 2. Reference data — public read, no write
-- ------------------------------------------------------------
revoke all on table public.domains             from anon, authenticated;
revoke all on table public.domain_translations from anon, authenticated;
grant select on table public.domains             to anon, authenticated;
grant select on table public.domain_translations to anon, authenticated;

drop policy if exists "domains are publicly readable" on public.domains;
create policy "domains are publicly readable"
  on public.domains for select using (true);

drop policy if exists "domain translations are publicly readable" on public.domain_translations;
create policy "domain translations are publicly readable"
  on public.domain_translations for select using (true);

-- ------------------------------------------------------------
-- 3. Questions — correct_index is withheld at the column level
-- ------------------------------------------------------------
revoke all on table public.questions             from anon, authenticated;
revoke all on table public.question_translations from anon, authenticated;

-- Note the deliberate omission of correct_index.
grant select (id, domain_id, difficulty, is_active, created_at)
  on table public.questions to anon, authenticated;
grant select (question_id, language_code, text, options)
  on table public.question_translations to anon, authenticated;

drop policy if exists "active questions are publicly readable" on public.questions;
create policy "active questions are publicly readable"
  on public.questions for select using (is_active = true);

drop policy if exists "question translations are publicly readable" on public.question_translations;
create policy "question translations are publicly readable"
  on public.question_translations for select using (
    exists (select 1 from public.questions q where q.id = question_id and q.is_active = true)
  );

-- ------------------------------------------------------------
-- 4. Profiles — own profile + accepted friends
-- ------------------------------------------------------------
revoke all on table public.profiles from anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (display_name, preferred_language) on table public.profiles to authenticated;

drop policy if exists "profiles are publicly readable" on public.profiles;
drop policy if exists "users read own profile" on public.profiles;
create policy "users read own profile"
  on public.profiles for select
  using (auth.uid() = id);

drop policy if exists "users read friends profiles" on public.profiles;
create policy "users read friends profiles"
  on public.profiles for select
  using (exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and (   (f.user_id = auth.uid() and f.friend_id = profiles.id)
           or (f.friend_id = auth.uid() and f.user_id = profiles.id))
  ));

-- `with check` was missing before, which let a user re-point their own row at
-- somebody else's id.
drop policy if exists "users can update own profile" on public.profiles;
create policy "users can update own profile"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- ------------------------------------------------------------
-- 5. Quiz sessions / answers — read own, write only via RPC
-- ------------------------------------------------------------
revoke all on table public.quiz_sessions from anon, authenticated;
revoke all on table public.quiz_answers  from anon, authenticated;
grant select on table public.quiz_sessions to authenticated;
grant select on table public.quiz_answers  to authenticated;

drop policy if exists "users manage own sessions" on public.quiz_sessions;
drop policy if exists "users read own sessions" on public.quiz_sessions;
create policy "users read own sessions"
  on public.quiz_sessions for select using (auth.uid() = user_id);

drop policy if exists "users manage own answers" on public.quiz_answers;
drop policy if exists "users read own answers" on public.quiz_answers;
create policy "users read own answers"
  on public.quiz_answers for select using (
    exists (select 1 from public.quiz_sessions s
            where s.id = session_id and s.user_id = auth.uid())
  );

-- ------------------------------------------------------------
-- 6. Reported questions — read own, insert only via RPC
--    (the old policy was `insert with check (true)`, which let anyone file a
--    report under somebody else's user_id, or mark it resolved)
-- ------------------------------------------------------------
revoke all on table public.reported_questions from anon, authenticated;
grant select on table public.reported_questions to authenticated;

drop policy if exists "anyone can report a question" on public.reported_questions;
drop policy if exists "users see own reported questions" on public.reported_questions;
create policy "users see own reported questions"
  on public.reported_questions for select using (auth.uid() = user_id);

-- ------------------------------------------------------------
-- 7. Friendships
-- ------------------------------------------------------------
revoke all on table public.friendships from anon, authenticated;
grant select on table public.friendships to authenticated;
grant insert (user_id, friend_id) on table public.friendships to authenticated;
grant update (status) on table public.friendships to authenticated;

drop policy if exists "users see own friendships" on public.friendships;
create policy "users see own friendships"
  on public.friendships for select
  using (auth.uid() = user_id or auth.uid() = friend_id);

drop policy if exists "users create friend requests" on public.friendships;
create policy "users create friend requests"
  on public.friendships for insert
  with check (auth.uid() = user_id and user_id <> friend_id);

-- `with check` was missing: the recipient of a request could rewrite the row's
-- user_id / friend_id and graft themselves onto an arbitrary friendship.
drop policy if exists "users respond to friend requests" on public.friendships;
create policy "users respond to friend requests"
  on public.friendships for update
  using (auth.uid() = friend_id)
  with check (auth.uid() = friend_id and status in ('pending','accepted'));

drop policy if exists "users withdraw own friend requests" on public.friendships;
create policy "users withdraw own friend requests"
  on public.friendships for delete
  using (auth.uid() = user_id or auth.uid() = friend_id);
grant delete on table public.friendships to authenticated;

-- ------------------------------------------------------------
-- 8. New-user trigger
--    `search_path` is pinned to '' and every object is schema-qualified —
--    without that, a SECURITY DEFINER function is a privilege-escalation
--    vector (an attacker who can create objects in a searched schema can
--    shadow the ones the function means to call).
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  v_name := coalesce(
    nullif(btrim(new.raw_user_meta_data->>'display_name'), ''),
    split_part(new.email, '@', 1)
  );
  -- Strip control characters and cap the length: this value is user-supplied.
  v_name := left(regexp_replace(v_name, '[[:cntrl:]]', '', 'g'), 32);

  insert into public.profiles (id, display_name)
  values (new.id, v_name)
  on conflict (id) do nothing;

  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ------------------------------------------------------------
-- 9. Default privileges — make sure future tables are not auto-exposed
-- ------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
