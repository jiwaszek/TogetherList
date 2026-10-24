#!/usr/bin/env bash
# Runs the backend SQL tests against a throwaway local PostgreSQL (15+).
#
# Needs PostgreSQL server binaries (initdb, pg_ctl, psql). Either:
#   * put them on PATH (Postgres.app, Homebrew `postgresql@16`, ...), or
#   * set PG_BIN=/path/to/postgres/bin, or
#   * let this script install the `pgserver` Python wheel (embedded Postgres 16)
#     into .build/pgvenv.
#
# The migration is applied on top of supabase/tests/local_supabase_stub.sql,
# which recreates the few Supabase objects it depends on (auth.users, auth.uid(),
# anon/authenticated roles, supabase_realtime publication).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "${PG_BIN:-}" ]]; then
  if command -v initdb >/dev/null 2>&1; then
    PG_BIN="$(dirname "$(command -v initdb)")"
  else
    VENV="$ROOT/.build/pgvenv"
    if [[ ! -x "$VENV/bin/python" ]]; then
      echo "Installing embedded PostgreSQL (pgserver) into $VENV ..."
      python3 -m venv "$VENV"
      "$VENV/bin/pip" install -q --upgrade pip
      "$VENV/bin/pip" install -q pgserver
    fi
    PG_BIN="$("$VENV/bin/python" -I -c 'import pgserver, pathlib; print(pathlib.Path(pgserver.__file__).parent / "pginstall" / "bin")')"
  fi
fi

WORK="$(mktemp -d)"
trap '"$PG_BIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

"$PG_BIN/initdb" -D "$WORK/data" -U postgres -A trust >/dev/null
"$PG_BIN/pg_ctl" -D "$WORK/data" -l "$WORK/log" -w \
  -o "-k $WORK -c listen_addresses='' -c wal_level=logical" start >/dev/null

PSQL=("$PG_BIN/psql" -h "$WORK" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -X)

"${PSQL[@]}" -f "$ROOT/supabase/tests/local_supabase_stub.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  "${PSQL[@]}" -f "$f"
done
"${PSQL[@]}" -f "$ROOT/supabase/tests/togetherlist_test.sql"
