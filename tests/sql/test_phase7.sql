-- ============================================================================
--  BioGas — database test-suite (Phase 7: feedstocks, feeding/OLR-HRT,
--  digestate, alarms). Runs on a FRESH database (shim + schema + seed).
--  Every check raises 'FAIL: …' and stops psql (ON_ERROR_STOP) on failure.
-- ============================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;
\o /dev/null

\set A   'a0000000-0000-0000-0000-00000000000a'
\set B   'b0000000-0000-0000-0000-00000000000b'
\set AADM 'a1000000-0000-0000-0000-000000000001'
\set AOP  'a2000000-0000-0000-0000-000000000002'
\set AVW  'a3000000-0000-0000-0000-000000000003'
\set BADM 'b1000000-0000-0000-0000-000000000001'
\set PADM 'f0000000-0000-0000-0000-00000000000f'
\set U1  'aa000000-0000-0000-0000-000000000001'
\set U2  'aa000000-0000-0000-0000-000000000002'
\set UB  'bb000000-0000-0000-0000-000000000001'

-- ---------------------------------------------------------------- helpers --
create or replace function public._t_assert(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAIL: %', msg; end if; end $$;
create or replace function public._t_as(u uuid) returns void language sql as $$
  select set_config('app.current_user_id', u::text, false); $$;
create or replace function public._t_fs(n text) returns uuid language sql stable as $$
  select id from public.feedstocks where tenant_id is null and name = n; $$;
create or replace function public._t_par(c text) returns uuid language sql stable as $$
  select id from public.parameters where tenant_id is null and code = c; $$;

-- ------------------------------------------------------------------ setup --
insert into public.tenants (id, name, slug) values (:'A', 'Tenant A', 'ta'), (:'B', 'Tenant B', 'tb');
insert into auth.users (id, email) values
  (:'AADM', 'aadm@a.gr'), (:'AOP', 'aop@a.gr'), (:'AVW', 'avw@a.gr'), (:'BADM', 'badm@b.gr'), (:'PADM', 'root@x.gr');
update public.profiles set tenant_id = :'A', role = 'admin'    where id = :'AADM';
update public.profiles set tenant_id = :'A', role = 'operator' where id = :'AOP';
update public.profiles set tenant_id = :'A', role = 'viewer'   where id = :'AVW';
update public.profiles set tenant_id = :'B', role = 'admin'    where id = :'BADM';
update public.profiles set is_platform_admin = true            where id = :'PADM';
insert into public.units (id, tenant_id, name, capacity_kw, digester_m3) values
  (:'U1', :'A', 'Χωνευτής 1', 500, 2500),
  (:'U2', :'A', 'Χωνευτής 2', 999, 4000),
  (:'UB', :'B', 'Χωνευτής Β', 600, 3000);

\echo '[T0] parameters: global rows are unique (NULLS NOT DISTINCT)'
do $$ begin
  begin
    insert into public.parameters (tenant_id, code) values (null, 'fos_tac');
    perform public._t_assert(false, 'duplicate global parameter must be rejected');
  exception when unique_violation then null; end;
end $$;
select public._t_assert((select count(*) from public.parameters where tenant_id is null and code = 'fos_tac') = 1, 'one global fos_tac');

-- ============================================================ feedstocks ==
\echo '[T1] feedstocks: visibility & write rules'
set role authenticated;
select public._t_as(:'AOP');
select public._t_assert((select count(*) from public.feedstocks where tenant_id is null) = 13, 'operator sees 13 global feedstocks');
insert into public.feedstocks (tenant_id, name, category, ts_pct, vs_pct, bmp, price_eur_t, cn_ratio)
values (:'A', 'Τοπικό υπόστρωμα Α', 'other', 20, 90, 300, 0, 25);
do $$ declare n int; begin
  update public.feedstocks set price_eur_t = 99 where tenant_id is null;
  get diagnostics n = row_count;
  perform public._t_assert(n = 0, 'operator must not update global feedstocks');
end $$;
select public._t_as(:'AVW');
do $$ begin
  begin
    insert into public.feedstocks (tenant_id, name) values ('a0000000-0000-0000-0000-00000000000a', 'X');
    perform public._t_assert(false, 'viewer must not create feedstocks');
  exception when insufficient_privilege then null; end;
end $$;
select public._t_as(:'BADM');
select public._t_assert((select count(*) from public.feedstocks where name = 'Τοπικό υπόστρωμα Α') = 0, 'tenant B must not see tenant A feedstock');
insert into public.feedstocks (tenant_id, name, category, ts_pct, vs_pct, bmp) values (:'B', 'Υπόστρωμα Β', 'other', 20, 90, 300);

-- ============================================================== feeding ==
\echo '[T2] feeding_daily: automatic OLR / HRT / expected CH4'
select public._t_as(:'AOP');
insert into public.feeding (tenant_id, unit_id, feed_date, feedstock_id, mass_t) values
  (:'A', :'U1', '2026-11-01', public._t_fs('Ενσίρωμα αραβοσίτου'), 22),
  (:'A', :'U1', '2026-11-01', public._t_fs('Υγρή κοπριά βοοειδών'), 30),
  (:'A', :'U1', '2026-11-01', public._t_fs('Τυρόγαλα (ορός γάλακτος)'), 8);
select public._t_assert((select round(olr, 2) from public.feeding_daily where unit_id = :'U1' and feed_date = '2026-11-01') = 3.69, 'OLR 3.69 kg VS/m3.d');
select public._t_assert((select round(hrt, 1) from public.feeding_daily where unit_id = :'U1' and feed_date = '2026-11-01') = 41.7, 'HRT 41.7 d');
select public._t_assert((select round(ch4_expected_m3) from public.feeding_daily where unit_id = :'U1' and feed_date = '2026-11-01') = 2932, 'expected CH4 2932 m3');
select public._t_assert((select mass_t from public.feeding_daily where unit_id = :'U1' and feed_date = '2026-11-01') = 60, 'mass 60 t');
select public._t_assert(not exists (select 1 from public.alerts where kind = 'feeding' and resolved_at is null), 'no feeding alarm at OLR 3.69');
select public._t_as(:'BADM');
select public._t_assert((select count(*) from public.feeding_daily) = 0, 'tenant B sees no tenant A feeding_daily rows');

\echo '[T3] replace_feeding RPC + OLR alarm (critical → resolved)'
select public._t_as(:'AOP');
select public._t_assert(public.replace_feeding(:'A', :'U1', '2026-11-02', jsonb_build_array(
  jsonb_build_object('feedstock_id', public._t_fs('Ενσίρωμα αραβοσίτου'), 'mass_t', 40),
  jsonb_build_object('feedstock_id', public._t_fs('Υγρή κοπριά βοοειδών'), 'mass_t', 30),
  jsonb_build_object('feedstock_id', public._t_fs('Τυρόγαλα (ορός γάλακτος)'), 'mass_t', 8),
  jsonb_build_object('feedstock_id', public._t_fs('Κοπριά πουλερικών'), 'mass_t', 0))) = 3, 'replace_feeding inserts 3 rows (zero mass skipped)');
select public._t_assert((select severity from public.alerts where kind = 'feeding' and metric = 'OLR' and unit_id = :'U1' and resolved_at is null) = 'critical', 'OLR 5.95 → critical');
select public._t_assert((select value from public.alerts where kind = 'feeding' and metric = 'OLR' and unit_id = :'U1') = 5.95, 'OLR alarm value 5.95');
-- replacing the same day must not duplicate rows
select public.replace_feeding(:'A', :'U1', '2026-11-02', jsonb_build_array(
  jsonb_build_object('feedstock_id', public._t_fs('Ενσίρωμα αραβοσίτου'), 'mass_t', 22),
  jsonb_build_object('feedstock_id', public._t_fs('Υγρή κοπριά βοοειδών'), 'mass_t', 30),
  jsonb_build_object('feedstock_id', public._t_fs('Τυρόγαλα (ορός γάλακτος)'), 'mass_t', 8)));
select public._t_assert((select count(*) from public.feeding where unit_id = :'U1' and feed_date = '2026-11-02') = 3, 'replace keeps 3 rows');
select public._t_assert((select resolved_at is not null from public.alerts where kind = 'feeding' and metric = 'OLR' and unit_id = :'U1'), 'OLR alarm resolved after correction');

\echo '[T4] digester volume change re-evaluates OLR & HRT (units trigger)'
select public._t_as(:'AADM');
update public.units set digester_m3 = 1000 where id = :'U1';
select public._t_assert((select severity from public.alerts where metric = 'OLR' and unit_id = :'U1' and resolved_at is null) = 'critical', 'OLR 9.23 → critical');
select public._t_assert((select severity from public.alerts where metric = 'HRT' and unit_id = :'U1' and resolved_at is null) = 'warning', 'HRT 16.7 → warning');
update public.units set digester_m3 = 2500 where id = :'U1';
select public._t_assert(not exists (select 1 from public.alerts where kind = 'feeding' and unit_id = :'U1' and resolved_at is null), 'feeding alarms resolved after restoring volume');

-- ============================================================ parameters ==
\echo '[T5] parameter alarm is state-based on the latest measurement'
select public._t_as(:'AOP');
insert into public.samples (id, tenant_id, unit_id, code, kind) values ('ac000000-0000-0000-0000-000000000001', :'A', :'U1', 'D-1', 'digester');
insert into public.analyses (tenant_id, sample_id, parameter_id, value, measured_at)
values (:'A', 'ac000000-0000-0000-0000-000000000001', public._t_par('fos_tac'), 0.55, '2026-11-05 08:00');
select public._t_assert((select severity from public.alerts where kind = 'parameter' and metric = 'FOS/TAC' and resolved_at is null) = 'critical', 'FOS/TAC 0.55 → critical');
insert into public.analyses (tenant_id, sample_id, parameter_id, value, measured_at)
values (:'A', 'ac000000-0000-0000-0000-000000000001', public._t_par('fos_tac'), 0.30, '2026-11-06 08:00');
select public._t_assert((select resolved_at is not null from public.alerts where metric = 'FOS/TAC'), 'FOS/TAC 0.30 → resolved');
insert into public.analyses (tenant_id, sample_id, parameter_id, value, measured_at)
values (:'A', 'ac000000-0000-0000-0000-000000000001', public._t_par('fos_tac'), 0.43, '2026-11-07 08:00');
select public._t_assert((select severity from public.alerts where metric = 'FOS/TAC' and resolved_at is null) = 'warning', 'FOS/TAC 0.43 → re-opened as warning');
select public._t_assert((select count(*) from public.alerts where metric = 'FOS/TAC') = 1, 'one alarm row per plant+parameter (deduplicated)');
delete from public.analyses where value = 0.43 and parameter_id = public._t_par('fos_tac');
select public._t_assert((select resolved_at is not null from public.alerts where metric = 'FOS/TAC'), 'deleting the latest re-evaluates → resolved');
-- informational parameters (no band) never alarm
insert into public.analyses (tenant_id, sample_id, parameter_id, value, measured_at)
values (:'A', 'ac000000-0000-0000-0000-000000000001', public._t_par('dig_n'), 9.9, '2026-11-07 08:00');
select public._t_assert(not exists (select 1 from public.alerts where metric like 'Ολικό άζωτο%'), 'no alarm for parameters without a band');

\echo '[T6] deleting a sample clears its alarms'
select public._t_as(:'AADM');
insert into public.samples (id, tenant_id, unit_id, code, kind) values ('ac000000-0000-0000-0000-000000000009', :'A', :'U2', 'D-9', 'digester');
insert into public.analyses (tenant_id, sample_id, parameter_id, value) values (:'A', 'ac000000-0000-0000-0000-000000000009', public._t_par('h2s'), 900);
select public._t_assert((select severity from public.alerts where metric = 'Υδρόθειο (H₂S)' and unit_id = :'U2' and resolved_at is null) = 'critical', 'H2S 900 → critical');
delete from public.samples where id = 'ac000000-0000-0000-0000-000000000009';
select public._t_assert((select resolved_at is not null from public.alerts where metric = 'Υδρόθειο (H₂S)' and unit_id = :'U2'), 'sample deleted → H2S alarm resolved');

-- ============================================================ production ==
\echo '[T7] production alarms, acknowledge, escalation resets ack + e-mail'
select public._t_as(:'AOP');
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours) values (:'A', :'U1', '2026-11-05', 48, 23.5);
select public._t_assert((select severity from public.alerts where metric = 'CH₄ %' and unit_id = :'U1' and resolved_at is null) = 'warning', 'CH4 48% → warning');
select public.acknowledge_alert((select id from public.alerts where metric = 'CH₄ %' and unit_id = :'U1'));
select public._t_assert((select acknowledged_at is not null and acknowledged_by = :'AOP'::uuid from public.alerts where metric = 'CH₄ %' and unit_id = :'U1'), 'acknowledged by operator');
reset role;
update public.alerts set emailed_at = now() where metric = 'CH₄ %';   -- as the Edge Function would
set role authenticated;
select public._t_as(:'AOP');
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours) values (:'A', :'U1', '2026-11-06', 44, 23.5);
select public._t_assert((select severity = 'critical' and acknowledged_at is null and emailed_at is null
                           from public.alerts where metric = 'CH₄ %' and unit_id = :'U1'), 'escalation → critical, ack + e-mail reset');
insert into public.production (tenant_id, unit_id, log_date, ch4_pct, chp_hours) values (:'A', :'U1', '2026-11-07', 53, 18);
select public._t_assert((select resolved_at is not null from public.alerts where metric = 'CH₄ %' and unit_id = :'U1'), 'CH4 53% → resolved');
select public._t_assert((select severity from public.alerts where metric = 'Ώρες ΣΗΘ' and unit_id = :'U1' and resolved_at is null) = 'warning', 'CHP 18 h → warning');

\echo '[T8] alarm write paths are locked down'
select public._t_as(:'AVW');
do $$ begin
  begin
    perform public.acknowledge_alert((select id from public.alerts where metric = 'Ώρες ΣΗΘ' limit 1));
    perform public._t_assert(false, 'viewer must not acknowledge');
  exception when insufficient_privilege then null; end;
end $$;
select public._t_as(:'BADM');
select public._t_assert((select count(*) from public.alerts where tenant_id = 'a0000000-0000-0000-0000-00000000000a') = 0, 'tenant B sees no tenant A alarms');
reset role;
select public._t_as(:'BADM');
create temp table _t_ids as select id from public.alerts where tenant_id = 'a0000000-0000-0000-0000-00000000000a' limit 1;
grant select on _t_ids to authenticated;
set role authenticated;
do $$ begin
  begin
    perform public.acknowledge_alert((select id from _t_ids));
    perform public._t_assert(false, 'tenant B must not acknowledge tenant A alarm');
  exception when insufficient_privilege then null; end;
end $$;
select public._t_as(:'AADM');
do $$ declare n int; begin
  update public.alerts set message = 'tampered';
  get diagnostics n = row_count;
  perform public._t_assert(n = 0, 'clients must not UPDATE alerts directly');
end $$;
do $$ begin
  begin
    insert into public.alerts (tenant_id, kind, dedupe_key) values ('a0000000-0000-0000-0000-00000000000a', 'parameter', 'fake');
    perform public._t_assert(false, 'clients must not INSERT alerts directly');
  exception when insufficient_privilege then null; end;
end $$;
do $$ begin
  begin
    perform public.raise_alert('a0000000-0000-0000-0000-00000000000a', null, 'parameter', 'x', 1, 'critical', 'fake', 'fake2');
    perform public._t_assert(false, 'raise_alert must not be callable by clients');
  exception when insufficient_privilege then null; end;
end $$;
do $$ begin
  begin
    perform public.clear_alert('anything');
    perform public._t_assert(false, 'clear_alert must not be callable by clients');
  exception when insufficient_privilege then null; end;
end $$;
do $$ begin
  begin
    perform public.reevaluate_alerts();
    perform public._t_assert(false, 'reevaluate_alerts must not be callable by clients');
  exception when insufficient_privilege then null; end;
end $$;

\echo '[T9] alert recipients: tenant admins only'
select public._t_as(:'AADM');
insert into public.alert_recipients (tenant_id, email, min_severity) values (:'A', 'ops@a.gr', 'critical');
select public._t_as(:'AOP');
do $$ begin
  begin
    insert into public.alert_recipients (tenant_id, email) values ('a0000000-0000-0000-0000-00000000000a', 'me@a.gr');
    perform public._t_assert(false, 'operator must not manage recipients');
  exception when insufficient_privilege then null; end;
end $$;
select public._t_assert((select count(*) from public.alert_recipients) = 0, 'operator cannot read recipients');
select public._t_as(:'BADM');
select public._t_assert((select count(*) from public.alert_recipients) = 0, 'tenant B cannot read tenant A recipients');

-- ============================================================= digestate ==
\echo '[T10] digestate: cumulative N/ha per recipient vs 170 kg N/ha/yr'
select public._t_as(:'AOP');
insert into public.digestate (tenant_id, unit_id, log_date, mass_t, destination, recipient, field_area_ha, n_kg_t)
values (:'A', :'U1', '2026-03-10', 150, 'field', 'Παπαδόπουλος Γ.', 10, 4.5);
select public._t_assert(not exists (select 1 from public.alerts where kind = 'digestate'), '67.5 kg N/ha → no alarm');
insert into public.digestate (tenant_id, unit_id, log_date, mass_t, destination, recipient, field_area_ha, n_kg_t)
values (:'A', :'U1', '2026-04-10', 200, 'field', 'παπαδόπουλος γ. ', 10, 4.5);   -- same recipient, different spelling
select public._t_assert((select severity from public.alerts where kind = 'digestate' and resolved_at is null) = 'warning', '157.5 kg N/ha → warning (≥ 90 % of limit)');
insert into public.digestate (tenant_id, unit_id, log_date, mass_t, destination, recipient, field_area_ha, n_kg_t)
values (:'A', :'U1', '2026-05-10', 50, 'field', 'Παπαδόπουλος Γ.', 10, 4.5);
select public._t_assert((select severity from public.alerts where kind = 'digestate' and resolved_at is null) = 'critical', '180 kg N/ha → critical');
insert into public.digestate (tenant_id, unit_id, log_date, mass_t, destination, recipient, n_kg_t)
values (:'A', :'U1', '2026-05-11', 500, 'storage', 'Παπαδόπουλος Γ.', 4.5);
select public._t_assert((select value from public.alerts where kind = 'digestate') = 180.0, 'storage transfers do not count towards field N');
delete from public.digestate where log_date = '2026-05-10';
select public._t_assert((select severity from public.alerts where kind = 'digestate' and resolved_at is null) = 'warning', 'delete → back to warning');
select public._t_assert((select count(*) from public.alerts where kind = 'digestate') = 1, 'one digestate alarm per recipient/year');

-- ============================================================= integrity ==
\echo '[T11] cross-tenant references are rejected'
select public._t_as(:'AOP');
do $$ begin
  begin
    insert into public.samples (tenant_id, unit_id, code, kind)
    values ('a0000000-0000-0000-0000-00000000000a', 'bb000000-0000-0000-0000-000000000001', 'X', 'digester');
    perform public._t_assert(false, 'sample on another tenant''s plant must fail');
  exception when check_violation then null; end;
end $$;
do $$ begin
  begin
    insert into public.production (tenant_id, unit_id, log_date)
    values ('a0000000-0000-0000-0000-00000000000a', 'bb000000-0000-0000-0000-000000000001', '2026-11-01');
    perform public._t_assert(false, 'production on another tenant''s plant must fail');
  exception when check_violation then null; end;
end $$;
reset role;
create temp table _t_fsb as select id from public.feedstocks where name = 'Υπόστρωμα Β';
grant select on _t_fsb to authenticated;
set role authenticated;
select public._t_as(:'AOP');
do $$ begin
  begin
    insert into public.feeding (tenant_id, unit_id, feed_date, feedstock_id, mass_t)
    values ('a0000000-0000-0000-0000-00000000000a', 'aa000000-0000-0000-0000-000000000001', '2026-11-03', (select id from _t_fsb), 5);
    perform public._t_assert(false, 'feeding with another tenant''s feedstock must fail');
  exception when check_violation then null; end;
end $$;
do $$ begin
  begin
    perform public.replace_feeding('a0000000-0000-0000-0000-00000000000a', 'bb000000-0000-0000-0000-000000000001', '2026-11-03', '[]'::jsonb);
    perform public._t_assert(false, 'replace_feeding on another tenant''s plant must fail');
  exception when foreign_key_violation then null; end;
end $$;
select public._t_as(:'AVW');
do $$ begin
  begin
    perform public.replace_feeding('a0000000-0000-0000-0000-00000000000a', 'aa000000-0000-0000-0000-000000000001', '2026-11-04',
      jsonb_build_array(jsonb_build_object('feedstock_id', public._t_fs('Ενσίρωμα αραβοσίτου'), 'mass_t', 10)));
    perform public._t_assert(false, 'viewer must not write feeding through the RPC');
  exception when insufficient_privilege then null; end;
end $$;

\echo '[T12] substrate TS/VS change re-evaluates OLR; used substrates cannot be deleted'
select public._t_as(:'AOP');
insert into public.feeding (tenant_id, unit_id, feed_date, feedstock_id, mass_t)
select :'A', :'U2', '2026-11-10', id, 100 from public.feedstocks where name = 'Τοπικό υπόστρωμα Α';
select public._t_assert((select severity from public.alerts where metric = 'OLR' and unit_id = :'U2' and resolved_at is null) = 'warning', 'local substrate 100 t → OLR 4.5 warning');
select public._t_as(:'AADM');
update public.feedstocks set ts_pct = 10 where name = 'Τοπικό υπόστρωμα Α';
select public._t_assert((select resolved_at is not null from public.alerts where metric = 'OLR' and unit_id = :'U2'), 'TS halved → OLR 2.25 → resolved');
do $$ begin
  begin
    delete from public.feedstocks where name = 'Τοπικό υπόστρωμα Α';
    perform public._t_assert(false, 'deleting a substrate used in feeding must fail');
  exception when foreign_key_violation then null; end;
end $$;

\echo '[T13] audit trail covers the new tables'
select public._t_as(:'AADM');
select public._t_assert((select count(*) from public.audit_log where entity = 'feeding') > 0, 'feeding is audited');
select public._t_assert((select count(*) from public.audit_log where entity = 'digestate') > 0, 'digestate is audited');

\echo '[T14] platform admin sees every tenant'
select public._t_as(:'PADM');
select public._t_assert((select count(distinct tenant_id) from public.feedstocks where tenant_id is not null) = 2, 'platform admin sees both tenants'' feedstocks');
reset role;
select public._t_assert(public.reevaluate_alerts() > 0, 'reevaluate_alerts runs for the service role');

reset role;
\echo 'ALL PHASE 7 DATABASE TESTS PASSED'
