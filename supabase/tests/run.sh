#!/usr/bin/env bash
# 로컬 Postgres에 스키마를 올리고 권한 테스트를 돌린다.
#
#   필요: postgresql-16 서버 바이너리 (initdb, pg_ctl), psql
#   사용: supabase/tests/run.sh
#
# Supabase의 auth/storage 스키마와 authenticated 롤은 stub.sql로 흉내 낸다.
# 실제 Supabase 프로젝트에 올릴 때는 migrations/만 적용한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/babyalbum-pgtest"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PORT="${PGPORT:-5433}"

export PATH="$PGBIN:$PATH"
export PGOPTIONS="--client-min-messages=warning"

cleanup() { pg_ctl -D "$WORK/pgdata" stop -m immediate >/dev/null 2>&1 || true; }
trap cleanup EXIT

rm -rf "$WORK"; mkdir -p "$WORK"
initdb -D "$WORK/pgdata" -U postgres --auth=trust -E UTF8 >/dev/null
pg_ctl -D "$WORK/pgdata" -o "-k $WORK -p $PORT -c listen_addresses=" -l "$WORK/pg.log" start >/dev/null
sleep 1

run() { psql -h "$WORK" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

run -f "$ROOT/supabase/tests/stub.sql"
run -f "$ROOT/supabase/migrations/0001_init.sql"
run -f "$ROOT/supabase/tests/rls_test.sql"
