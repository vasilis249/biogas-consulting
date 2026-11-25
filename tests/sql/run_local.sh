#!/usr/bin/env bash
# ============================================================================
#  BioGas — database test runner (throwaway local PostgreSQL ≥ 15 cluster)
#
#    tests/sql/run_local.sh
#
#  1. FRESH   : shim → db/schema.sql → db/seed.sql (×2, idempotent) → tests
#  2. UPGRADE : shim → schema/seed/0006 as of $BASELINE (reproduces the old
#               duplicate-parameter bug) → 0007, 0009, 0010 (each ×2, idempotent;
#               0010 also meets duplicated/impossible legacy production rows)
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
psqlx -d fresh -f tests/sql/test_phase10.sql

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
psqlx -d upgraded -f db/migrations/0009_red3_sustainability.sql >/dev/null
psqlx -d upgraded -f db/migrations/0009_red3_sustainability.sql >/dev/null
ok "migration 0009 applied twice (idempotent)"
# legacy production data: a duplicated day and an impossible CH₄ value, as the
# old form allowed (docs/OPERATOR_REVIEW.md §9 bugs 2–3)
psqlx -d upgraded -c "
  insert into units (id, tenant_id, name) values ('cd000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-00000000000c', 'Legacy Χ1');
  insert into production (id, tenant_id, unit_id, log_date, ch4_pct, created_at) values
    ('ce000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-00000000000c', 'cd000000-0000-0000-0000-000000000001', '2026-11-01', 52, now() - interval '2 hours'),
    ('ce000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-00000000000c', 'cd000000-0000-0000-0000-000000000001', '2026-11-01', 53, now() - interval '1 hour'),
    ('ce000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-00000000000c', 'cd000000-0000-0000-0000-000000000001', '2026-11-02', 531, now());"
psqlx -d upgraded -f db/migrations/0010_production_integrity_roles.sql >/dev/null 2>&1
[ "$(psqlx -d upgraded -At -c "select string_agg(id::text, ',') from production where log_date = '2026-11-01'")" = "ce000000-0000-0000-0000-000000000002" ] \
  && ok "0010: duplicated day collapsed to the latest entry"
[ "$(psqlx -d upgraded -At -c "select meta->>'ch4_pct' from audit_log where action = 'dedupe' and entity_id = 'ce000000-0000-0000-0000-000000000001'")" = "52" ] \
  && ok "0010: removed duplicate preserved verbatim in audit_log"
[ "$(psqlx -d upgraded -At -c "select convalidated from pg_constraint where conname = 'production_ch4_pct_check'")" = "f" ] \
  && ok "0010: dirty legacy row keeps the CH₄ check NOT VALID instead of failing the upgrade"
if psqlx -d upgraded -c "insert into production (tenant_id, unit_id, log_date, ch4_pct) values ('c0000000-0000-0000-0000-00000000000c', 'cd000000-0000-0000-0000-000000000001', '2026-11-03', 200)" >/dev/null 2>&1; then
  echo "✘ NOT VALID check must still reject new rows"; exit 1; fi
ok "0010: new impossible values rejected even before validation"
psqlx -d upgraded -c "update production set ch4_pct = 53.1 where id = 'ce000000-0000-0000-0000-000000000003'"
psqlx -d upgraded -f db/migrations/0010_production_integrity_roles.sql >/dev/null
[ "$(psqlx -d upgraded -At -c "select bool_and(convalidated) from pg_constraint where conrelid = 'production'::regclass and contype = 'c'")" = "t" ] \
  && ok "0010: re-run after the data fix validates every check (idempotent)"
[ "$(psqlx -d upgraded -At -c "select red_class from feedstocks where category='manure' limit 1")" = "manure" ] \
  && ok "RED III class back-filled from category on upgrade"
[ "$(psqlx -d upgraded -At -c "select count(*) - count(distinct code) from parameters where tenant_id is null")" = 0 ] \
  && ok "duplicate global parameters merged"
[ "$(psqlx -d upgraded -At -c "select count(*) from analyses a join parameters p on p.id = a.parameter_id where p.code = 'fos_tac'")" = 1 ] \
  && ok "legacy analysis re-pointed to the surviving parameter"
[ "$(psqlx -d upgraded -At -c "select severity from alerts where kind = 'parameter' and resolved_at is null")" = "critical" ] \
  && ok "existing data raised its alarm on upgrade (FOS/TAC 0.6 → critical)"
psqlx -d upgraded -At -f tests/sql/fingerprint.sql > "$W/upgraded.fp"

echo "▶ schema.sql mirrors the migrations verbatim"
for ph in 9:0009_red3_sustainability 10:0010_production_integrity_roles; do
  n="${ph%%:*}"; f="db/migrations/${ph#*:}.sql"
  blk() { sed -n "/^-- >>> BEGIN PHASE$n OBJECTS/,/^-- <<< END PHASE$n OBJECTS/p" "$1"; }
  if [ -n "$(blk "$f")" ] && diff <(blk db/schema.sql) <(blk "$f") >/dev/null; then ok "PHASE$n block identical"
  else echo "✘ PHASE$n block in db/schema.sql differs from $f"; exit 1; fi
done

echo "▶ FRESH vs UPGRADE schema fingerprint"
if diff -u "$W/fresh.fp" "$W/upgraded.fp" > "$W/fp.diff"; then
  ok "identical ($(wc -l < "$W/fresh.fp") objects compared)"
else
  echo "✘ schema drift between db/schema.sql and the migrations:"; cat "$W/fp.diff"; exit 1
fi
echo "ALL DATABASE CHECKS PASSED"
