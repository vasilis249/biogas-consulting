-- ============================================================================
--  BioGas — database tests for migration 0011: trend alarms (configurable per
--  parameter), daily digester temperature, planned CHP stop, falling CH₄,
--  feeding notes. Runs on the FRESH database after test_phase7/10.sql.
-- ============================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;
\o /dev/null

\set A    'a0000000-0000-0000-0000-00000000000a'
\set B    'b0000000-0000-0000-0000-00000000000b'
\set AOP  'a2000000-0000-0000-0000-000000000002'
\set AVW  'a3000000-0000-0000-0000-000000000003'
\set U3   'aa000000-0000-0000-0000-000000000003'
\set UB   'bb000000-0000-0000-0000-000000000001'

reset role;
create or replace function public._t_assert(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', msg; end if; end $$;
create or replace function public._t_as(u uuid) returns void language sql as $$
  select set_config('app.current_user_id', u::text, false); $$;
create or replace function public._t_state(stmt text) returns text language plpgsql as $$
begin execute stmt; return '';
exception when others then return sqlstate; end $$;
-- one lab sample with a single measurement
create or replace function public._t_lab(t uuid, u uuid, code text, d date, v numeric) returns void language plpgsql as $$
declare sid uuid := gen_random_uuid();
begin
  insert into public.samples (id, tenant_id, unit_id, code, kind, taken_at) values (sid, t, u, code || '-' || d, 'digester', d);
  insert into public.analyses (tenant_id, sample_id, parameter_id, value, measured_at)
  values (t, sid, (select id from public.parameters where tenant_id is null and parameters.code = _t_lab.code), v, d + time '09:00');
end $$;
create or replace function public._t_alert(k text) returns public.alerts language sql stable as $$
  select * from public.alerts where dedupe_key like k and resolved_at is null limit 1; $$;

insert into public.units (id, tenant_id, name, capacity_kw, digester_m3) values (:'U3', :'A', 'Χωνευτής 3 (P11)', 500, 2500);

\echo '[P11.1] FOS/TAC trend: +0.05 within 14 days warns before the absolute limit'
select public._t_assert((select trend_delta = 0.05 and trend_days = 14 from public.parameters where tenant_id is null and code = 'fos_tac'),
  'seed: global FOS/TAC trend rule +0.05 / 14 d');
select public._t_lab(:'A', :'U3', 'fos_tac', '2026-08-11', 0.31);   -- 3 weeks before: outside the window
select public._t_lab(:'A', :'U3', 'fos_tac', '2026-08-25', 0.33);
select public._t_lab(:'A', :'U3', 'fos_tac', '2026-09-01', 0.36);
select public._t_assert(public._t_alert('trend:%' || :'U3' || ':%') is null, '0.33 → 0.36 (+0.03) → no trend alarm');
select public._t_lab(:'A', :'U3', 'fos_tac', '2026-09-08', 0.38);
select public._t_assert((public._t_alert('trend:%' || :'U3' || ':%')).severity = 'warning', '0.33 → 0.38 (+0.05) → trend warning');
select public._t_assert((public._t_alert('trend:%' || :'U3' || ':%')).message like '%ανοδική τάση +0.05 σε 14 ημ. (0.33 → 0.38%', 'trend message explains the rise');
select public._t_assert(public._t_alert('param:%' || :'U3' || ':%') is null, 'still inside 0.2–0.4: no absolute alarm yet (the trend warned first)');
select public._t_lab(:'A', :'U3', 'fos_tac', '2026-09-15', 0.48);
select public._t_assert((public._t_alert('trend:%' || :'U3' || ':%')).severity = 'critical', '0.36 → 0.48 (+0.12 ≥ 2×0.05) → critical');
select public._t_lab(:'A', :'U3', 'fos_tac', '2026-09-29', 0.40);
select public._t_assert(public._t_alert('trend:%' || :'U3' || ':%') is null, 'falling back (0.48 → 0.40) resolves the trend alarm');

\echo '[P11.2] falling rule (negative delta) and switching the rule off'
update public.parameters set trend_delta = -0.2, trend_days = 7 where tenant_id is null and code = 'ph_dig';
select public._t_lab(:'A', :'U3', 'ph_dig', '2026-09-20', 7.62);
select public._t_lab(:'A', :'U3', 'ph_dig', '2026-09-26', 7.40);
select public._t_assert((public._t_alert('trend:%' || :'U3' || ':' || (select id from public.parameters where tenant_id is null and code = 'ph_dig'))).message
  like '%καθοδική τάση -0.22%', 'pH 7.62 → 7.40 within 7 d → falling-trend alarm');
update public.parameters set trend_delta = null, trend_days = null where tenant_id is null and code = 'ph_dig';
select public.reevaluate_alerts(:'A');
select public._t_assert(public._t_alert('trend:%' || :'U3' || ':' || (select id from public.parameters where tenant_id is null and code = 'ph_dig')) is null,
  'rule removed → alarm resolved on re-evaluation');
select public._t_assert(public._t_state($q$update public.parameters set trend_days = 0 where tenant_id is null and code = 'ph_dig'$q$) = '23514',
  'trend_days must be 1–90');

\echo '[P11.3] planned CHP stop, temperature drop, falling CH4'
set role authenticated;
select public._t_as(:'AOP');
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours, planned_stop, digester_temp_c)
values (:'A', :'U3', '2026-09-01', 53.4, 12, true, 41.0);
select public._t_assert(public._t_alert('prod-chp:%' || :'U3') is null, 'planned stop (12 h) raises no CHP availability alarm');
update public.production set planned_stop = false where unit_id = :'U3' and log_date = '2026-09-01';
select public._t_assert((public._t_alert('prod-chp:%' || :'U3')).severity = 'critical', 'same hours without planned stop → alarm');
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours, digester_temp_c)
values (:'A', :'U3', '2026-09-02', 52.5, 23.5, 39.8);
select public._t_assert(public._t_alert('prod-chp:%' || :'U3') is null, 'normal day resolves the CHP alarm');
select public._t_assert((public._t_alert('prod-temp:%' || :'U3')).severity = 'warning', '41.0 → 39.8 °C (−1.2) → temperature warning');
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours, digester_temp_c)
values (:'A', :'U3', '2026-09-03', 51.6, 23.5, 37.5);
select public._t_assert((public._t_alert('prod-temp:%' || :'U3')).severity = 'critical', '39.8 → 37.5 °C (−2.3) → critical');
select public._t_assert(public._t_alert('prod-ch4-fall:%' || :'U3') is null, 'two days of falling CH4 is not yet a trend');
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours, digester_temp_c)
values (:'A', :'U3', '2026-09-04', 50.9, 23.5, 37.6);
select public._t_assert(public._t_alert('prod-temp:%' || :'U3') is null, 'temperature stable again → resolved');
select public._t_assert((public._t_alert('prod-ch4-fall:%' || :'U3')).message like '%3 ημέρες συνεχόμενα: 53.4 → 50.9%', 'CH4 53.4 → 52.5 → 51.6 → 50.9 → falling-CH4 warning');
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours, digester_temp_c)
values (:'A', :'U3', '2026-09-05', 51.4, 23.5, 38.4);
select public._t_assert(public._t_alert('prod-ch4-fall:%' || :'U3') is null, 'CH4 recovers → resolved');
select public._t_assert(public._t_state(format(
  $q$insert into public.production (tenant_id, unit_id, log_date, digester_temp_c) values (%L, %L, '2026-09-06', 95)$q$, :'A', :'U3')) = '23514',
  'digester temperature 95 °C rejected');

\echo '[P11.4] feeding notes'
select public._t_assert(public._t_state(format(
  $q$insert into public.feeding_notes (tenant_id, unit_id, feed_date, note) values (%L, %L, '2026-09-02', 'Κόψιμο 25%% VS λόγω FOS/TAC 0,48')$q$, :'A', :'U3')) = '',
  'operator records why the ration changed');
select public._t_assert(public._t_state(format(
  $q$insert into public.feeding_notes (tenant_id, unit_id, feed_date, note) values (%L, %L, '2026-09-02', 'δεύτερη')$q$, :'A', :'U3')) = '23505',
  'one note per digester and day');
select public._t_assert(public._t_state(format(
  $q$insert into public.feeding_notes (tenant_id, unit_id, feed_date, note) values (%L, %L, '2026-09-03', '   ')$q$, :'A', :'U3')) = '23514',
  'blank note rejected');
select public._t_assert(public._t_state(format(
  $q$insert into public.feeding_notes (tenant_id, unit_id, feed_date, note) values (%L, %L, '2026-09-03', 'x')$q$, :'A', :'UB')) in ('23514', '42501'),
  'note on another tenant''s digester rejected');
select public._t_as(:'AVW');
select public._t_assert(public._t_state(format(
  $q$insert into public.feeding_notes (tenant_id, unit_id, feed_date, note) values (%L, %L, '2026-09-04', 'viewer')$q$, :'A', :'U3')) = '42501',
  'viewer cannot write notes');
select public._t_assert((select count(*) from public.feeding_notes where unit_id = :'U3') = 1, 'viewer reads the tenant''s notes');
select public._t_assert(not has_function_privilege('authenticated', 'public.eval_param_trend(uuid,uuid,uuid)', 'execute'),
  'eval_param_trend is not callable through the API');
reset role;
select public._t_assert(exists (select 1 from public.audit_log where entity = 'feeding_notes' and action = 'insert'), 'feeding notes are audited');

\o
\echo 'ALL PHASE 11 DATABASE TESTS PASSED'
