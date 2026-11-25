-- ============================================================================
--  BioGas — database tests for migration 0010 (operator-review P1 fixes):
--  production integrity (one row per digester/day, physical ranges) and
--  admin-only plant setup / alarm limits.
--  Runs on the FRESH database right after test_phase7.sql (re-uses its
--  tenants, users and digesters). Fails with 'FAIL: …' (ON_ERROR_STOP).
-- ============================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;
\o /dev/null

\set A    'a0000000-0000-0000-0000-00000000000a'
\set AADM 'a1000000-0000-0000-0000-000000000001'
\set AOP  'a2000000-0000-0000-0000-000000000002'
\set AVW  'a3000000-0000-0000-0000-000000000003'
\set U1   'aa000000-0000-0000-0000-000000000001'
\set U2   'aa000000-0000-0000-0000-000000000002'

reset role;
create or replace function public._t_assert(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', msg; end if; end $$;
create or replace function public._t_as(u uuid) returns void language sql as $$
  select set_config('app.current_user_id', u::text, false); $$;
-- Runs a statement and returns the SQLSTATE it raised ('' when it succeeded).
create or replace function public._t_state(stmt text) returns text language plpgsql as $$
begin execute stmt; return '';
exception when others then return sqlstate; end $$;

\echo '[P10.1] production: one row per digester and day'
set role authenticated;
select public._t_as(:'AOP');
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours, flare_hours)
values (:'A', :'U1', '2026-10-01', 53, 23.5, 0.5);
select public._t_assert(public._t_state(format(
  $q$insert into public.production (tenant_id, unit_id, log_date, ch4_pct) values (%L, %L, '2026-10-01', 52)$q$, :'A', :'U1')) = '23505',
  'second log for the same digester and day → unique_violation');
select public._t_assert(public._t_state(format(
  $q$insert into public.production (tenant_id, unit_id, log_date, ch4_pct) values (%L, %L, '2026-10-01', 52)$q$, :'A', :'U2')) = '',
  'same day on another digester is allowed');
select public._t_assert((select flare_hours from public.production where unit_id = :'U1' and log_date = '2026-10-01') = 0.5,
  'flare hours are stored');

\echo '[P10.2] production: physical range checks'
select public._t_assert(public._t_state(format(
  $q$insert into public.production (tenant_id, unit_id, log_date, ch4_pct) values (%L, %L, '2026-10-02', 531)$q$, :'A', :'U1')) = '23514',
  'CH4 531 % rejected');
select public._t_assert(public._t_state(format(
  $q$insert into public.production (tenant_id, unit_id, log_date, chp_hours) values (%L, %L, '2026-10-02', 31)$q$, :'A', :'U1')) = '23514',
  'CHP 31 h rejected');
select public._t_assert(public._t_state(format(
  $q$insert into public.production (tenant_id, unit_id, log_date, flare_hours) values (%L, %L, '2026-10-02', 25)$q$, :'A', :'U1')) = '23514',
  'flare 25 h rejected');
select public._t_assert(public._t_state(format(
  $q$insert into public.production (tenant_id, unit_id, log_date, biogas_m3) values (%L, %L, '2026-10-02', -500)$q$, :'A', :'U1')) = '23514',
  'negative biogas rejected');
select public._t_assert(public._t_state(format(
  $q$insert into public.production (tenant_id, unit_id, log_date, kwh_el) values (%L, %L, '2026-10-02', -1)$q$, :'A', :'U1')) = '23514',
  'negative kWh rejected');
select public._t_assert(public._t_state(format(
  $q$update public.production set ch4_pct = 101 where unit_id = %L and log_date = '2026-10-01'$q$, :'U1')) = '23514',
  'range checks apply to updates too');
select public._t_assert(public._t_state(format(
  $q$insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours, flare_hours, biogas_m3, kwh_el)
     values (%L, %L, '2026-10-02', 0, 24, 0, 0, 0)$q$, :'A', :'U1')) = '',
  'boundary values (0 %, 24 h, 0) accepted');

\echo '[P10.3] operators cannot change digesters'
select public._t_as(:'AOP');
select public._t_assert(public._t_state(format(
  $q$insert into public.units (tenant_id, name) values (%L, 'Χ3 operator')$q$, :'A')) = '42501',
  'operator cannot create a digester');
update public.units set digester_m3 = 1 where id = :'U1';
delete from public.units where id = :'U2';
reset role;
select public._t_assert((select digester_m3 from public.units where id = :'U1') = 2500, 'operator update of a digester has no effect');
select public._t_assert(exists (select 1 from public.units where id = :'U2'), 'operator cannot delete a digester');
set role authenticated;
select public._t_as(:'AVW');
select public._t_assert(public._t_state(format(
  $q$insert into public.units (tenant_id, name) values (%L, 'Χ3 viewer')$q$, :'A')) = '42501',
  'viewer cannot create a digester');
select public._t_as(:'AADM');
update public.units set notes = 'admin edit' where id = :'U1';
select public._t_assert((select notes from public.units where id = :'U1') = 'admin edit', 'tenant admin edits a digester');
select public._t_assert(public._t_state(format(
  $q$insert into public.units (tenant_id, name) values (%L, 'Χ3 admin')$q$, :'A')) = '',
  'tenant admin creates a digester');

\echo '[P10.4] operators cannot change alarm limits'
select public._t_as(:'AOP');
select public._t_assert(public._t_state(format(
  $q$insert into public.parameters (tenant_id, code, ideal_min, ideal_max) values (%L, 'fos_tac', 0, 0.9)$q$, :'A')) = '42501',
  'operator cannot override the FOS/TAC limit');
select public._t_as(:'AADM');
select public._t_assert(public._t_state(format(
  $q$insert into public.parameters (tenant_id, code, ideal_min, ideal_max) values (%L, 'p10_test', 0, 1)$q$, :'A')) = '',
  'tenant admin overrides a limit');
select public._t_as(:'AOP');
update public.parameters set ideal_max = 99 where tenant_id = :'A' and code = 'p10_test';
delete from public.parameters where tenant_id = :'A' and code = 'p10_test';
reset role;
select public._t_assert((select ideal_max from public.parameters where tenant_id = :'A' and code = 'p10_test') = 1,
  'operator cannot edit or delete a tenant limit');

\echo '[P10.5] operators keep day-to-day write access'
set role authenticated;
select public._t_as(:'AOP');
select public._t_assert(public._t_state(format(
  $q$update public.production set ch4_pct = 54 where unit_id = %L and log_date = '2026-10-01'$q$, :'U1')) = '',
  'operator corrects a production log');
reset role;
select public._t_assert((select ch4_pct from public.production where unit_id = :'U1' and log_date = '2026-10-01') = 54,
  'operator correction stored');

\o
\echo 'ALL PHASE 10 DATABASE TESTS PASSED'
