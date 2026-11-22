#!/usr/bin/env bash
# ============================================================================
#  BioGas — database test runner (throwaway local PostgreSQL ≥ 15 cluster)
#
#    tests/sql/run_local.sh
#
#  1. FRESH   : shim → db/schema.sql → db/seed.sql (×2, idempotent) → tests
#  2. UPGRADE : shim → schema/seed/0006 as of $BASELINE (reproduces the old
#               duplicate-parameter bug) → 0007 (×2, idempotent)
#  3. Proves FRESH and UPGRADE end with the same schema (fingerprint diff).
#
#  Env: PGBIN (dir with initdb/pg_ctl/psql), BASELINE (git rev, default 356e588)
# ============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
if [ -z "${PGBIN:-}" ]; then
  if command -v initdb >/dev/null 2>&1; then PGBIN="$(dirname "$(command -v initdb)")"
  else PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"; fi
fi
BASELINE="${BASELINE:-356e588}"
PORT="${PGPORT_TEST:-54329}"
W="$(mktemp -d /tmp/biogas-sqltest.XXXXXX)"
AS=()
if [ "$(id -u)" = 0 ]; then AS=(runuser -u postgres --); chown postgres "$W"; fi

cleanup() { "${AS[@]}" "$PGBIN/pg_ctl" -D "$W/data" -m fast -w stop >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

"${AS[@]}" mkdir -p "$W/data" "$W/sock"
"${AS[@]}" "$PGBIN/initdb" -D "$W/data" -A trust -U postgres --encoding=UTF8 --locale=C.UTF-8 >/dev/null
"${AS[@]}" "$PGBIN/pg_ctl" -D "$W/data" -o "-p $PORT -k $W/sock -c listen_addresses=''" -l "$W/pg.log" -w start >/dev/null

export PGOPTIONS='-c client_min_messages=warning'
psqlx() { "$PGBIN/psql" -h "$W/sock" -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }

echo "▶ FRESH install"
psqlx -d postgres -c "create database fresh"
psqlx -d fresh -f tests/sql/supabase_shim.sql
psqlx -d fresh -f db/schema.sql
psqlx -d fresh -f db/seed.sql
psqlx -d fresh -f db/seed.sql
ok "schema + seed applied (seed re-run is idempotent)"
psqlx -d fresh -At -f tests/sql/fingerprint.sql > "$W/fresh.fp"
psqlx -d fresh -f tests/sql/test_phase7.sql

echo "▶ UPGRADE path from $BASELINE"
psqlx -d postgres -c "create database upgraded"
psqlx -d upgraded -f tests/sql/supabase_shim.sql
git show "$BASELINE:db/schema.sql"                  | psqlx -d upgraded
git show "$BASELINE:db/seed.sql"                    | psqlx -d upgraded
git show "$BASELINE:db/migrations/0006_biogas.sql"  | psqlx -d upgraded
DUP=$(psqlx -d upgraded -At -c "select count(*) - count(distinct code) from parameters where tenant_id is null")
[ "$DUP" -gt 0 ] && ok "baseline reproduces duplicated global parameters ($DUP)"
# legacy data pointing at a duplicate parameter row must survive the merge
psqlx -d upgraded -c "
  insert into tenants (id, name, slug) values ('c0000000-0000-0000-0000-00000000000c', 'Legacy', 'legacy');
  insert into samples (id, tenant_id, code, kind) values ('cc000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-00000000000c', 'L-1', 'digester');
  insert into analyses (tenant_id, sample_id, parameter_id, value)
  select 'c0000000-0000-0000-0000-00000000000c', 'cc000000-0000-0000-0000-000000000001', id, 0.6
    from parameters where tenant_id is null and code = 'fos_tac' order by created_at desc, id desc limit 1;"
psqlx -d upgraded -f db/migrations/0007_feedstock_digestate_alerts.sql >/dev/null
psqlx -d upgraded -f db/migrations/0007_feedstock_digestate_alerts.sql >/dev/null
ok "migration 0007 applied twice (idempotent)"
[ "$(psqlx -d upgraded -At -c "select count(*) - count(distinct code) from parameters where tenant_id is null")" = 0 ] \
  && ok "duplicate global parameters merged"
[ "$(psqlx -d upgraded -At -c "select count(*) from analyses a join parameters p on p.id = a.parameter_id where p.code = 'fos_tac'")" = 1 ] \
  && ok "legacy analysis re-pointed to the surviving parameter"
[ "$(psqlx -d upgraded -At -c "select severity from alerts where kind = 'parameter' and resolved_at is null")" = "critical" ] \
  && ok "existing data raised its alarm on upgrade (FOS/TAC 0.6 → critical)"
psqlx -d upgraded -At -f tests/sql/fingerprint.sql > "$W/upgraded.fp"

echo "▶ FRESH vs UPGRADE schema fingerprint"
if diff -u "$W/fresh.fp" "$W/upgraded.fp" > "$W/fp.diff"; then
  ok "identical ($(wc -l < "$W/fresh.fp") objects compared)"
else
  echo "✘ schema drift between db/schema.sql and the migrations:"; cat "$W/fp.diff"; exit 1
fi
echo "ALL DATABASE CHECKS PASSED"
