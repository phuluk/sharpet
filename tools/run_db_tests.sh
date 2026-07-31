#!/usr/bin/env bash
# Spin up a throwaway Postgres, emulate the parts of Supabase the schema needs,
# apply db/01..05 and run the security tests. Nothing touches the real project.
#
#   ./tools/run_db_tests.sh
#
# Requires a local PostgreSQL 14+ (initdb, pg_ctl, psql on PATH).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGDATA="${PGDATA:-$(mktemp -d)/pgdata}"
PGPORT="${PGPORT:-55432}"
PGHOST="${PGHOST:-/tmp}"
export PGDATA PGPORT PGHOST

cleanup() { pg_ctl -D "$PGDATA" stop -m immediate >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> initdb in $PGDATA"
initdb -D "$PGDATA" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null
pg_ctl -D "$PGDATA" -o "-k $PGHOST -p $PGPORT -c listen_addresses=''" -l "$PGDATA/server.log" start >/dev/null
sleep 2

psql_run() { psql -h "$PGHOST" -p "$PGPORT" -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

echo "==> emulating Supabase roles and auth schema"
psql_run <<'SQL'
create role anon nologin;
create role authenticated nologin;
create role supabase_auth_admin nologin;
create schema if not exists auth;
-- Supabase installs extensions into this schema by default; 06_hardening.sql
-- assumes it already exists, same as it can on a real Supabase project.
create schema if not exists extensions;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  raw_user_meta_data jsonb default '{}'::jsonb,
  last_sign_in_at timestamptz
);
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema public, auth to anon, authenticated;
-- Supabase hands out blanket table grants; 04_security.sql must undo them.
alter default privileges in schema public grant all on tables to anon, authenticated;
SQL

psql_run -f "$ROOT/db/01_schema.sql" >/dev/null && echo "==> 01_schema"
psql_run -f "$ROOT/db/02_seed_domains.sql" >/dev/null && echo "==> 02_seed_domains"

echo "==> 03_seed_questions (all parts)"
for f in "$ROOT"/db/03_seed_questions/*.sql; do
  psql_run -f "$f" >/dev/null
done

psql_run -f "$ROOT/db/04_security.sql" >/dev/null && echo "==> 04_security"
psql_run -f "$ROOT/db/05_rpc.sql" >/dev/null && echo "==> 05_rpc"

# 06_hardening.sql needs the `http` extension (pgsql-http) and a `vault`
# schema, neither of which a vanilla local Postgres has — Supabase installs
# both as trusted extensions, this throwaway cluster does not. The test
# script stubs verify_turnstile() itself, but `create extension http` runs
# unconditionally at the top of the file, so it has to actually be
# installed locally (e.g. `apt install postgresql-<ver>-http` /
# `pgxn install http`) for this step to succeed. If it's not available,
# comment out this line and note that 06 was applied to Supabase directly
# without a local dry run.
psql_run -f "$ROOT/db/06_hardening.sql" >/dev/null && echo "==> 06_hardening"
psql_run -f "$ROOT/db/07_admin.sql" >/dev/null && echo "==> 07_admin"
psql_run -f "$ROOT/db/08_geo.sql" >/dev/null && echo "==> 08_geo"
psql_run -f "$ROOT/db/09_region_block.sql" >/dev/null && echo "==> 09_region_block"

echo "==> security tests"
psql -h "$PGHOST" -p "$PGPORT" -U postgres -v ON_ERROR_STOP=1 \
     -f "$ROOT/db/tests/security_tests.sql" 2>&1 |
  grep -E 'PASS|FAIL|ERROR|PASSED'
