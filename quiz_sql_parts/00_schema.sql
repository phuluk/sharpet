-- Quiz questions schema for Supabase
-- Run this FIRST, then run the data part files in order (01, 02, 03, ...)

create table if not exists public.quiz_questions (
  id integer primary key,
  domain text not null,
  domain_en text not null,
  domain_de text not null,
  domain_cs text not null,
  difficulty text not null,
  question_en text not null,
  question_de text not null,
  question_cs text not null,
  correct_answer_en text not null,
  correct_answer_de text not null,
  correct_answer_cs text not null,
  distractors jsonb not null
);

create index if not exists idx_quiz_questions_domain on public.quiz_questions (domain);
create index if not exists idx_quiz_questions_difficulty on public.quiz_questions (difficulty);
