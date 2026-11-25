-- ============================================================================
--  BioGas — database tests for migration 0012: acknowledgement comments,
--  shift log & tasks, incidents (with alarm), contacts, emergency cards,
--  CHP maintenance by running hours. Runs on the FRESH database after
--  test_phase7/10/11.sql (re-uses their tenants, users and digesters).
-- ============================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;
\o /dev/null

\set A    'a0000000-0000-0000-0000-00000000000a'
\set B    'b0000000-0000-0000-0000-00000000000b'
\set AADM 'a1000000-0000-0000-0000-000000000001'
\set AOP  'a2000000-0000-0000-0000-000000000002'
\set AVW  'a3000000-0000-0000-0000-000000000003'
\set BADM 'b1000000-0000-0000-0000-000000000001'
\set U1   'aa000000-0000-0000-0000-000000000001'
\set U3   'aa000000-0000-0000-0000-000000000003'
\set UB   'bb000000-0000-0000-0000-000000000001'
\set I1   'ab000000-0000-0000-0000-000000000001'
\set MP1  'ac000000-0000-0000-0000-000000000001'

reset role;
create or replace function public._t_assert(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', msg; end if; end $$;
create or replace function public._t_as(u uuid) returns void language sql as $$
  select set_config('app.current_user_id', u::text, false); $$;
create or replace function public._t_state(stmt text) returns text language plpgsql as $$
begin execute stmt; return '';
exception when others then return sqlstate; end $$;

\echo '[P12.1] acknowledgement with comment and who'
-- a fresh warning on Χ3: CH4 48 % (test_phase11 left Χ3 at 51.4 %)
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours) values (:'A', :'U3', '2026-09-10', 48, 23.5);
set role authenticated;
select public._t_as(:'AOP');
select public.acknowledge_alert((select id from public.alerts where dedupe_key like 'prod-ch4:%' || :'U3'), 'Ενημερώθηκε ο μηχανικός, έλεγχος αισθητήρα CH₄');
select public._t_assert((select acknowledged_by = :'AOP'::uuid and ack_comment = 'Ενημερώθηκε ο μηχανικός, έλεγχος αισθητήρα CH₄'
                           from public.alerts where dedupe_key like 'prod-ch4:%' || :'U3'), 'comment and operator stored with the acknowledgement');
select public._t_assert((select created_at < acknowledged_at from public.alerts where dedupe_key like 'prod-ch4:%' || :'U3'),
  'created_at keeps «since when», separate from the acknowledgement time');
reset role;
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours) values (:'A', :'U3', '2026-09-11', 44, 23.5);
select public._t_assert((select acknowledged_at is null and ack_comment is null from public.alerts where dedupe_key like 'prod-ch4:%' || :'U3'),
  'escalation to critical clears acknowledgement AND its comment');
set role authenticated;
select public._t_as(:'AOP');
select public.acknowledge_alert((select id from public.alerts where dedupe_key like 'prod-ch4:%' || :'U3'));
select public._t_assert((select acknowledged_at is not null and ack_comment is null from public.alerts where dedupe_key like 'prod-ch4:%' || :'U3'),
  '1-argument acknowledge_alert still works');
select public._t_as(:'AVW');
select public._t_assert(public._t_state(format($q$select public.acknowledge_alert(%L::uuid, 'x')$q$,
  (select id from public.alerts where tenant_id = :'A' limit 1))) = '42501', 'viewer cannot acknowledge');

\echo '[P12.2] incidents raise and resolve an alarm'
select public._t_as(:'AOP');
insert into public.incidents (id, tenant_id, unit_id, kind, severity, title, started_at)
values (:'I1', :'A', :'U1', 'chp_trip', 'major', 'Trip ΣΗΘ — υψηλή θερμοκρασία νερού ψύξης', '2026-09-12 03:10+03');
select public._t_assert((select severity = 'warning' and kind = 'incident' and resolved_at is null from public.alerts where dedupe_key = 'incident:' || :'I1'),
  'major incident in progress → warning alarm');
update public.incidents set severity = 'emergency' where id = :'I1';
select public._t_assert((select severity = 'critical' and message like 'ΕΚΤΑΚΤΗ ΑΝΑΓΚΗ ΣΕ ΕΞΕΛΙΞΗ%03:10%' from public.alerts where dedupe_key = 'incident:' || :'I1'),
  'emergency → critical, message with local start time');
update public.incidents set ended_at = '2026-09-12 04:25+03', actions = 'Καθαρισμός ψυγείου, επανεκκίνηση' where id = :'I1';
select public._t_assert((select resolved_at is not null from public.alerts where dedupe_key = 'incident:' || :'I1'), 'closing the incident resolves its alarm');
insert into public.incidents (tenant_id, kind, title) values (:'A', 'other', 'Μικρή διαρροή νερού');
select public._t_assert(not exists (select 1 from public.alerts a join public.incidents i on a.dedupe_key = 'incident:' || i.id where i.title = 'Μικρή διαρροή νερού'),
  'minor incident → no alarm');
select public._t_assert(public._t_state(format($q$insert into public.incidents (tenant_id, kind, title, started_at, ended_at)
  values (%L, 'other', 'x', '2026-09-12 10:00', '2026-09-12 09:00')$q$, :'A')) = '23514', 'end before start rejected');
select public._t_assert(public._t_state(format($q$insert into public.incidents (tenant_id, unit_id, kind, title) values (%L, %L, 'other', 'x')$q$, :'A', :'UB')) = '23514',
  'incident on another tenant''s digester rejected');
select public._t_as(:'AVW');
select public._t_assert(public._t_state(format($q$insert into public.incidents (tenant_id, kind, title) values (%L, 'other', 'viewer')$q$, :'A')) = '42501',
  'viewer cannot log incidents');
select public._t_assert((select count(*) from public.incidents where tenant_id = :'A') = 2, 'viewer reads incidents');

\echo '[P12.3] shift log & carried-over tasks'
select public._t_as(:'AOP');
insert into public.shift_log (tenant_id, shift_date, shift, body) values (:'A', '2026-09-12', 'night', 'Trip ΣΗΘ 03:10, επανεκκίνηση 04:25. Προσοχή θερμοκρασία ψύξης.');
insert into public.shift_tasks (id, tenant_id, unit_id, title) values ('ad000000-0000-0000-0000-000000000001', :'A', :'U1', 'Έλεγχος ψυγείου ΣΗΘ κάθε 2 ώρες');
update public.shift_tasks set done_at = now(), done_by = :'AOP', done_note = 'ΟΚ, καθαρό' where id = 'ad000000-0000-0000-0000-000000000001';
select public._t_assert((select done_by = :'AOP'::uuid from public.shift_tasks where id = 'ad000000-0000-0000-0000-000000000001'), 'operator closes a task');
select public._t_assert(public._t_state(format($q$insert into public.shift_log (tenant_id, shift_date, shift, body) values (%L, '2026-09-12', 'evening', 'x')$q$, :'A')) = '23514',
  'unknown shift name rejected');
select public._t_assert(public._t_state(format($q$insert into public.shift_log (tenant_id, shift_date, shift, body) values (%L, '2026-09-12', 'morning', '  ')$q$, :'A')) = '23514',
  'empty hand-over note rejected');
select public._t_as(:'BADM');
select public._t_assert((select count(*) from public.shift_log) = 0 and (select count(*) from public.shift_tasks) = 0, 'other tenant sees nothing');

\echo '[P12.4] contacts & emergency cards'
select public._t_as(:'AOP');
select public._t_assert((select count(*) from public.emergency_cards where tenant_id is null) = 8, 'operator sees the 8 global emergency cards');
select public._t_assert(public._t_state(format($q$insert into public.contacts (tenant_id, name, phone) values (%L, 'x', '1')$q$, :'A')) = '42501',
  'operator cannot edit the contact list');
select public._t_assert(public._t_state(format($q$insert into public.emergency_cards (tenant_id, scenario, title, steps) values (%L, 'gas_leak', 'x', 'y')$q$, :'A')) = '42501',
  'operator cannot override an emergency card');
select public._t_as(:'AADM');
insert into public.contacts (tenant_id, name, role, phone, is_emergency) values (:'A', 'Πυροσβεστική', 'Έκτακτη ανάγκη', '199', true);
insert into public.emergency_cards (tenant_id, scenario, title, steps) values (:'A', 'gas_leak', 'Διαρροή βιοαερίου — Μονάδα Α', 'Βήμα 1');
select public._t_assert(public._t_state(format($q$insert into public.emergency_cards (tenant_id, scenario, title, steps) values (%L, 'gas_leak', 'dup', 'y')$q$, :'A')) = '23505',
  'one override per scenario');
select public._t_assert(public._t_state($q$update public.emergency_cards set steps = 'hacked' where tenant_id is null and scenario = 'fire'$q$) = ''
  and (select steps <> 'hacked' from public.emergency_cards where tenant_id is null and scenario = 'fire'), 'tenant admin cannot change a global template');
select public._t_as(:'BADM');
select public._t_assert(not exists (select 1 from public.emergency_cards where tenant_id = :'A'), 'tenant B does not see tenant A''s cards');
select public._t_assert((select count(*) from public.contacts) = 0, 'tenant B does not see tenant A''s contacts');

\echo '[P12.5] CHP maintenance by running hours'
select public._t_as(:'AADM');
insert into public.maintenance_plans (id, tenant_id, unit_id, task, interval_hours, last_done_on) values (:'MP1', :'A', :'U1', 'Αλλαγή λαδιών', 2000, '2026-09-30');
select public._t_assert((select hours_since from public.maintenance_status where id = :'MP1')
  = (select coalesce(sum(chp_hours), 0) from public.production where unit_id = :'U1' and log_date > '2026-09-30'), 'hours since service = Σ CHP hours after it');
select public._t_assert((select hours_left = interval_hours - hours_since from public.maintenance_status where id = :'MP1'), 'hours left');
select public._t_as(:'AOP');
update public.maintenance_plans set interval_hours = 99999 where id = :'MP1';
select public._t_assert((select interval_hours from public.maintenance_plans where id = :'MP1') = 2000, 'operator cannot change the plan');
insert into public.maintenance_log (tenant_id, plan_id, done_on, engine_hours, notes) values (:'A', :'MP1', '2026-11-06', 41250, 'Λάδι + φίλτρο');
select public._t_assert((select last_done_on from public.maintenance_plans where id = :'MP1') = '2026-11-06', 'logging a service moves last_done_on');
select public._t_assert((select hours_since from public.maintenance_status where id = :'MP1')
  = (select coalesce(sum(chp_hours), 0) from public.production where unit_id = :'U1' and log_date > '2026-11-06'), 'counter restarts after the service');
delete from public.maintenance_log where plan_id = :'MP1';
select public._t_assert((select last_done_on from public.maintenance_plans where id = :'MP1') is null, 'deleting the record rolls last_done_on back');
select public._t_as(:'BADM');
select public._t_assert(public._t_state(format($q$insert into public.maintenance_log (tenant_id, plan_id, done_on) values (%L, %L, '2026-11-06')$q$, :'B', :'MP1')) = '23514',
  'cannot log a service on another tenant''s plan');
select public._t_assert(not exists (select 1 from public.maintenance_status), 'tenant B sees no maintenance status of A');

\echo '[P12.6] API exposure'
select public._t_assert(has_function_privilege('authenticated', 'public.acknowledge_alert(uuid,text)', 'execute'), 'acknowledge_alert(uuid,text) callable');
select public._t_assert(not has_function_privilege('authenticated', 'public.eval_incident_alert(uuid)', 'execute'), 'eval_incident_alert internal');
reset role;
select public._t_assert((select count(distinct entity) from public.audit_log
  where entity in ('shift_log','shift_tasks','incidents','contacts','emergency_cards','maintenance_plans','maintenance_log')) = 7, 'all new tables audited');

\o
\echo 'ALL PHASE 12 DATABASE TESTS PASSED'
