-- ============================================================
-- Sharpet — 01_schema.sql
-- Tables, constraints and indexes. Idempotent: safe to re-run.
--
-- Run order:  01_schema  →  02_seed_domains  →  03_seed_questions
--             →  04_security  →  05_rpc
-- ============================================================

-- ------------------------------------------------------------
-- 1. DOMAINS (language-independent core row + per-language name)
-- ------------------------------------------------------------
create table if not exists public.domains (
  id serial primary key,
  color text default '#4FD1FF'
);

do $$ begin
  alter table public.domains
    add constraint domains_color_format check (color ~ '^#[0-9A-Fa-f]{6}$');
exception when duplicate_object then null; end $$;

create table if not exists public.domain_translations (
  domain_id int references public.domains(id) on delete cascade,
  language_code text not null check (language_code in ('en','de','cs')),
  name text not null,
  primary key (domain_id, language_code)
);

do $$ begin
  alter table public.domain_translations
    add constraint domain_translations_name_len check (char_length(name) between 1 and 80);
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 2. QUESTIONS (language-independent core + per-language text/options)
-- ------------------------------------------------------------
create table if not exists public.questions (
  id serial primary key,
  domain_id int references public.domains(id) on delete cascade,
  correct_index int not null,   -- index into options; identical across languages.
                                -- NEVER exposed to clients: see 04_security.sql
                                -- (column-level grants) and 05_rpc.sql.
  difficulty text default 'medium',
  is_active boolean default true,
  created_at timestamptz default now()
);

alter table public.questions add column if not exists difficulty text default 'medium';

do $$ begin
  alter table public.questions
    add constraint questions_correct_index_range check (correct_index between 0 and 9);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.questions
    add constraint questions_difficulty check (difficulty in ('easy','medium','hard'));
exception when duplicate_object then null; end $$;

create table if not exists public.question_translations (
  question_id int references public.questions(id) on delete cascade,
  language_code text not null check (language_code in ('en','de','cs')),
  text text not null,
  options jsonb not null,   -- e.g. ["FTP","SFTP","SMTP","ICMP"] — same order across languages
  primary key (question_id, language_code)
);

do $$ begin
  alter table public.question_translations
    add constraint question_translations_options_shape
    check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 10);
exception when duplicate_object then null; end $$;

create index if not exists idx_questions_domain_active
  on public.questions(domain_id) where is_active;
create index if not exists idx_question_translations_lang
  on public.question_translations(language_code);

-- ------------------------------------------------------------
-- 3. PROFILES
-- ------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  preferred_language text default 'en' check (preferred_language in ('en','de','cs')),
  created_at timestamptz default now()
);

-- Upper bound only. A minimum length is enforced in the signup form and in
-- handle_new_user(); adding a minimum here would break rows created before
-- this constraint existed.
do $$ begin
  alter table public.profiles
    add constraint profiles_display_name_len check (display_name is null or char_length(display_name) <= 32);
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- 4. QUIZ SESSIONS + ANSWERS (registered users only)
--    Written exclusively through the SECURITY DEFINER functions in
--    05_rpc.sql — clients have SELECT rights only.
-- ------------------------------------------------------------
create table if not exists public.quiz_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  domain_ids int[] not null,
  language_code text default 'en',
  num_answer_options int not null,
  num_questions int not null,
  correct_count int default 0,
  total_answered int default 0,
  started_at timestamptz default now(),
  ended_at timestamptz
);

do $$ begin
  alter table public.quiz_sessions
    add constraint quiz_sessions_language_code check (language_code in ('en','de','cs'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.quiz_sessions
    add constraint quiz_sessions_num_answer_options check (num_answer_options between 2 and 4);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.quiz_sessions
    add constraint quiz_sessions_num_questions check (num_questions between 1 and 100);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.quiz_sessions
    add constraint quiz_sessions_counts_nonneg check (correct_count >= 0 and total_answered >= 0);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.quiz_sessions
    add constraint quiz_sessions_domain_ids_len
    check (array_length(domain_ids, 1) between 1 and 50);
exception when duplicate_object then null; end $$;

create table if not exists public.quiz_answers (
  id uuid primary key default gen_random_uuid(),
  session_id uuid references public.quiz_sessions(id) on delete cascade not null,
  question_id int references public.questions(id) not null,
  domain_id int references public.domains(id),   -- snapshot of the question's domain at answer
                                                 -- time, so per-domain accuracy stays correct
                                                 -- even if a question is later recategorised
  selected_index int not null,
  is_correct boolean not null,
  answered_at timestamptz default now()
);

alter table public.quiz_answers add column if not exists domain_id int references public.domains(id);

do $$ begin
  alter table public.quiz_answers
    add constraint quiz_answers_selected_index_range check (selected_index between 0 and 9);
exception when duplicate_object then null; end $$;

-- One row per question per session: prevents a client from farming the same
-- question repeatedly to inflate its stats.
create unique index if not exists uniq_quiz_answers_session_question
  on public.quiz_answers(session_id, question_id);

-- Backfill domain_id for rows created before that column existed
update public.quiz_answers qa
set domain_id = q.domain_id
from public.questions q
where qa.question_id = q.id and qa.domain_id is null;

create index if not exists idx_quiz_answers_session on public.quiz_answers(session_id);
create index if not exists idx_quiz_answers_domain on public.quiz_answers(domain_id);
create index if not exists idx_quiz_answers_answered_at on public.quiz_answers(answered_at);
create index if not exists idx_quiz_sessions_user_started on public.quiz_sessions(user_id, started_at desc);

-- ------------------------------------------------------------
-- 5. REPORTED QUESTIONS
-- ------------------------------------------------------------
create table if not exists public.reported_questions (
  id uuid primary key default gen_random_uuid(),
  question_id int references public.questions(id) not null,
  user_id uuid references auth.users(id) on delete set null,
  session_id uuid references public.quiz_sessions(id) on delete set null,
  language_code text default 'en',
  reason text,
  resolved boolean default false,
  created_at timestamptz default now()
);

alter table public.reported_questions add column if not exists session_id uuid references public.quiz_sessions(id) on delete set null;

do $$ begin
  alter table public.reported_questions
    add constraint reported_questions_reason_len check (reason is null or char_length(reason) <= 500);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.reported_questions
    add constraint reported_questions_language_code check (language_code in ('en','de','cs'));
exception when duplicate_object then null; end $$;

create index if not exists idx_reported_questions_user on public.reported_questions(user_id);
create index if not exists idx_reported_questions_question on public.reported_questions(question_id);
create index if not exists idx_reported_questions_created on public.reported_questions(created_at desc);

-- ------------------------------------------------------------
-- 6. FRIENDSHIPS
-- ------------------------------------------------------------
create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  friend_id uuid references auth.users(id) on delete cascade not null,
  status text check (status in ('pending','accepted')) default 'pending',
  created_at timestamptz default now(),
  unique (user_id, friend_id)
);

do $$ begin
  alter table public.friendships
    add constraint friendships_no_self check (user_id <> friend_id);
exception when duplicate_object then null; end $$;

create index if not exists idx_friendships_friend on public.friendships(friend_id);

-- ------------------------------------------------------------
-- 7. PRIVATE CONFIG (never exposed through the API)
--    Lives outside the `public` schema, so PostgREST cannot reach it at all.
-- ------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from anon, authenticated, public;

create table if not exists private.app_config (
  key text primary key,
  value text not null
);
revoke all on table private.app_config from anon, authenticated, public;
