-- ============================================================================
-- Migration 0010 — operator-review P1 fixes (docs/OPERATOR_REVIEW.md §9)
--
--   * production : one row per digester and day — unique (unit_id, log_date).
--                  Existing duplicates are collapsed to the most recently
--                  entered row; every removed row is preserved verbatim in
--                  audit_log (action 'dedupe', meta = the full row), so
--                  nothing is lost silently.
--   * production : physical range checks — CH₄ 0–100 %, CHP / flare hours
--                  0–24 h, quantities and energy ≥ 0. Added NOT VALID and then
--                  validated when the existing data is clean; if an old row
--                  violates a check the constraint still guards every new
--                  insert/update and a NOTICE names the constraint.
--   * roles      : plant configuration (units = digesters) and alarm limits
--                  (parameters = ideal ranges) are admin-only. Operators keep
--                  write access to day-to-day data (samples, production,
--                  feeding, digestate, …).
--
-- Idempotent: safe to run more than once. Mirrored verbatim into
-- db/schema.sql between the PHASE10 markers so a fresh install is identical.
-- ============================================================================

-- >>> BEGIN PHASE10 OBJECTS
-- Tenant admin (or platform admin) — the role allowed to change plant setup.
create or replace function public.is_tenant_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_platform_admin()
      or public.auth_role() = 'admin';
$$;

-- ---- production: one log per digester and day -----------------------------
do $$
declare d record;
begin
  for d in
    select p.*
      from public.production p
     where p.unit_id is not null
       and exists (select 1 from public.production q
                    where q.unit_id = p.unit_id and q.log_date = p.log_date
                      and (q.created_at, q.id) > (p.created_at, p.id))
  loop
    insert into public.audit_log (tenant_id, user_id, action, entity, entity_id, meta)
    values (d.tenant_id, null, 'dedupe', 'production', d.id, to_jsonb(d));
    delete from public.production where id = d.id;
  end loop;
end $$;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'production_unit_day_key' and conrelid = 'public.production'::regclass) then
    alter table public.production add constraint production_unit_day_key unique (unit_id, log_date);
  end if;
end $$;

-- ---- production: physical ranges ------------------------------------------
do $$
declare c record;
begin
  for c in select * from (values
      ('production_ch4_pct_check',     'ch4_pct is null or (ch4_pct >= 0 and ch4_pct <= 100)'),
      ('production_chp_hours_check',   'chp_hours is null or (chp_hours >= 0 and chp_hours <= 24)'),
      ('production_flare_hours_check', 'flare_hours is null or (flare_hours >= 0 and flare_hours <= 24)'),
      ('production_feedstock_t_check', 'feedstock_t is null or feedstock_t >= 0'),
      ('production_biogas_m3_check',   'biogas_m3 is null or biogas_m3 >= 0'),
      ('production_kwh_el_check',      'kwh_el is null or kwh_el >= 0'),
      ('production_kwh_th_check',      'kwh_th is null or kwh_th >= 0')
    ) as t(name, expr)
  loop
    if not exists (select 1 from pg_constraint where conname = c.name and conrelid = 'public.production'::regclass) then
      execute format('alter table public.production add constraint %I check (%s) not valid', c.name, c.expr);
    end if;
    begin
      execute format('alter table public.production validate constraint %I', c.name);
    exception when check_violation then
      raise notice 'production: % kept NOT VALID — existing rows violate it; new rows are checked', c.name;
    end;
  end loop;
end $$;

-- ---- roles: plant configuration & alarm limits are admin-only --------------
drop policy if exists units_write on public.units;
create policy units_write on public.units for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.is_tenant_admin()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.is_tenant_admin()));

drop policy if exists parameters_write on public.parameters;
create policy parameters_write on public.parameters for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.is_tenant_admin()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.is_tenant_admin()));
-- <<< END PHASE10 OBJECTS
