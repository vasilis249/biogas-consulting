-- ============================================================================
-- Migration 0012 — shift & safety (docs/OPERATOR_REVIEW.md Top-10 #2, #8, #10)
--
--   * alerts            : ack_comment; acknowledge_alert(uuid, text) records who
--                         and why (the 1-argument version stays as a wrapper);
--                         new kind 'incident'. raise_alert() also clears the
--                         comment when an alarm re-opens or escalates.
--   * shift_log         : hand-over note per shift (πρωινή / απογευματινή / νυχτερινή).
--   * shift_tasks       : open items carried over from shift to shift until done.
--   * incidents         : incident log (type, severity, start/end, actions, who
--                         was notified, photo). A major / emergency incident
--                         still in progress raises an alarm (e-mail digest and,
--                         later, SMS) and resolves it when it is closed.
--   * contacts          : phone list (emergency services, ΔΕΔΔΗΕ, CHP service …);
--                         admin-maintained.
--   * emergency_cards   : one-page action cards per scenario. Global templates
--                         (tenant_id null, db/seed.sql) + tenant overrides.
--   * maintenance_plans / maintenance_log / maintenance_status : CHP service
--                         intervals by running hours (sum of production.chp_hours
--                         since the last service).
--
-- Idempotent: safe to run more than once. Mirrored verbatim into
-- db/schema.sql between the PHASE12 markers so a fresh install is identical.
-- ============================================================================

-- >>> BEGIN PHASE12 OBJECTS
-- ---- alerts: comment on acknowledgement, incident kind ----------------------
alter table public.alerts add column if not exists ack_comment text;
alter table public.alerts drop constraint if exists alerts_kind_check;
alter table public.alerts add constraint alerts_kind_check
  check (kind in ('parameter','production','feeding','digestate','incident'));

create or replace function public.raise_alert(p_tenant uuid, p_unit uuid, p_kind text, p_metric text,
                                              p_value numeric, p_severity text, p_message text, p_key text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.alerts as al (tenant_id, unit_id, kind, metric, value, severity, message, dedupe_key)
  values (p_tenant, p_unit, p_kind, p_metric, p_value, p_severity, p_message, p_key)
  on conflict (dedupe_key) do update set
    unit_id         = excluded.unit_id,
    metric          = excluded.metric,
    value           = excluded.value,
    message         = excluded.message,
    severity        = excluded.severity,
    updated_at      = now(),
    created_at      = case when al.resolved_at is not null then now() else al.created_at end,
    acknowledged_at = case when al.resolved_at is not null
                             or (al.severity = 'warning' and excluded.severity = 'critical')
                           then null else al.acknowledged_at end,
    acknowledged_by = case when al.resolved_at is not null
                             or (al.severity = 'warning' and excluded.severity = 'critical')
                           then null else al.acknowledged_by end,
    ack_comment     = case when al.resolved_at is not null
                             or (al.severity = 'warning' and excluded.severity = 'critical')
                           then null else al.ack_comment end,
    emailed_at      = case when al.resolved_at is not null
                             or (al.severity = 'warning' and excluded.severity = 'critical')
                           then null else al.emailed_at end,
    resolved_at     = null;
end;
$$;

create or replace function public.acknowledge_alert(p_id uuid, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.alerts where id = p_id;
  if not found then raise exception 'alert not found' using errcode = 'P0002'; end if;
  if not (public.is_platform_admin() or (v_tenant = public.auth_tenant_id() and public.can_write())) then
    raise exception 'not allowed to acknowledge this alert' using errcode = '42501';
  end if;
  update public.alerts
     set acknowledged_at = now(), acknowledged_by = auth.uid(), updated_at = now(),
         ack_comment = nullif(btrim(coalesce(p_comment, '')), '')
   where id = p_id;
end;
$$;

create or replace function public.acknowledge_alert(p_id uuid)
returns void language sql security definer set search_path = public as $$
  select public.acknowledge_alert(p_id, null::text);
$$;

-- ---- shift log & carried-over tasks ----------------------------------------
create table if not exists public.shift_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  shift_date  date not null,
  shift       text not null check (shift in ('morning','afternoon','night')),
  body        text not null check (btrim(body) <> ''),
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists idx_shift_log_tenant_date on public.shift_log (tenant_id, shift_date desc);

create table if not exists public.shift_tasks (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  unit_id     uuid references public.units (id) on delete set null,
  title       text not null check (btrim(title) <> ''),
  due_date    date,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  done_at     timestamptz,
  done_by     uuid references public.profiles (id) on delete set null,
  done_note   text
);
create index if not exists idx_shift_tasks_open on public.shift_tasks (tenant_id) where done_at is null;

-- ---- incidents ---------------------------------------------------------------
create table if not exists public.incidents (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  unit_id      uuid references public.units (id) on delete set null,
  kind         text not null check (kind in ('chp_trip','gas_leak','overpressure','blackout','foam','fire','injury','frost','spill','other')),
  severity     text not null default 'minor' check (severity in ('minor','major','emergency')),
  title        text not null check (btrim(title) <> ''),
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  description  text,
  actions      text,
  notified     text,
  photo_path   text,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  constraint incidents_period_check check (ended_at is null or ended_at >= started_at)
);
create index if not exists idx_incidents_tenant_started on public.incidents (tenant_id, started_at desc);

-- ---- contacts & emergency cards ---------------------------------------------
create table if not exists public.contacts (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete cascade,
  name          text not null check (btrim(name) <> ''),
  role          text,
  phone         text,
  phone2        text,
  notes         text,
  is_emergency  boolean not null default false,
  sort_order    integer not null default 100,
  created_at    timestamptz not null default now()
);
create index if not exists idx_contacts_tenant on public.contacts (tenant_id);

create table if not exists public.emergency_cards (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references public.tenants (id) on delete cascade,
  scenario    text not null,
  title       text not null check (btrim(title) <> ''),
  steps       text not null check (btrim(steps) <> ''),
  sort_order  integer not null default 100,
  created_at  timestamptz not null default now(),
  constraint emergency_cards_tenant_scenario_key unique nulls not distinct (tenant_id, scenario)
);

-- ---- CHP maintenance by running hours ---------------------------------------
create table if not exists public.maintenance_plans (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants (id) on delete cascade,
  unit_id         uuid not null references public.units (id) on delete cascade,
  task            text not null check (btrim(task) <> ''),
  interval_hours  numeric not null check (interval_hours > 0),
  last_done_on    date,
  notes           text,
  created_at      timestamptz not null default now()
);
create index if not exists idx_maintenance_plans_tenant on public.maintenance_plans (tenant_id);

create table if not exists public.maintenance_log (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete cascade,
  plan_id       uuid not null references public.maintenance_plans (id) on delete cascade,
  done_on       date not null,
  engine_hours  numeric check (engine_hours is null or engine_hours >= 0),
  notes         text,
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists idx_maintenance_log_plan on public.maintenance_log (plan_id, done_on desc);

-- Running hours since the last service = Σ production.chp_hours after last_done_on.
create or replace view public.maintenance_status with (security_invoker = true) as
select mp.id, mp.tenant_id, mp.unit_id, mp.task, mp.interval_hours, mp.last_done_on, mp.notes,
       coalesce(h.hours, 0)                       as hours_since,
       mp.interval_hours - coalesce(h.hours, 0)   as hours_left
  from public.maintenance_plans mp
  left join lateral (
    select sum(p.chp_hours) as hours
      from public.production p
     where p.unit_id = mp.unit_id and p.tenant_id = mp.tenant_id
       and (mp.last_done_on is null or p.log_date > mp.last_done_on)
  ) h on true;

-- A service record moves the plan's last_done_on (operators may log a service
-- without being allowed to edit the plan itself).
create or replace function public.trg_maintenance_log_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_plan uuid := coalesce(new.plan_id, old.plan_id);
begin
  update public.maintenance_plans
     set last_done_on = (select max(done_on) from public.maintenance_log where plan_id = v_plan)
   where id = v_plan;
  if tg_op = 'UPDATE' and old.plan_id is distinct from new.plan_id then
    update public.maintenance_plans
       set last_done_on = (select max(done_on) from public.maintenance_log where plan_id = old.plan_id)
     where id = old.plan_id;
  end if;
  return null;
end;
$$;
drop trigger if exists maintenance_log_sync on public.maintenance_log;
create trigger maintenance_log_sync after insert or update or delete on public.maintenance_log
  for each row execute function public.trg_maintenance_log_sync();

-- ---- incident alarm ----------------------------------------------------------
create or replace function public.eval_incident_alert(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  i       record;
  v_key   text := 'incident:' || p_id;
  v_uname text;
begin
  select * into i from public.incidents where id = p_id;
  if not found or i.ended_at is not null or i.severity = 'minor' then
    perform public.clear_alert(v_key); return;
  end if;
  select name into v_uname from public.units where id = i.unit_id;
  perform public.raise_alert(i.tenant_id, i.unit_id, 'incident',
    case i.kind when 'chp_trip' then 'Συμβάν: ΣΗΘ trip' when 'gas_leak' then 'Συμβάν: διαρροή αερίου'
                when 'overpressure' then 'Συμβάν: υπερπίεση' when 'blackout' then 'Συμβάν: μπλακ άουτ'
                when 'foam' then 'Συμβάν: αφρισμός' when 'fire' then 'Συμβάν: πυρκαγιά'
                when 'injury' then 'Συμβάν: τραυματισμός' when 'frost' then 'Συμβάν: παγετός'
                when 'spill' then 'Συμβάν: διαρροή υγρών' else 'Συμβάν' end,
    null,
    case when i.severity = 'emergency' then 'critical' else 'warning' end,
    format('%s ΣΕ ΕΞΕΛΙΞΗ: %s · %s · από %s',
           case when i.severity = 'emergency' then 'ΕΚΤΑΚΤΗ ΑΝΑΓΚΗ' else 'Σοβαρό συμβάν' end,
           i.title, coalesce(v_uname, 'μονάδα'),
           to_char(i.started_at at time zone 'Europe/Athens', 'DD/MM/YYYY HH24:MI')),
    v_key);
end;
$$;

create or replace function public.trg_incidents_alarm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then perform public.clear_alert('incident:' || old.id); return null; end if;
  perform public.eval_incident_alert(new.id);
  return null;
end;
$$;
drop trigger if exists alarm_incidents on public.incidents;
create trigger alarm_incidents after insert or update or delete on public.incidents
  for each row execute function public.trg_incidents_alarm();

-- ---- tenant-reference guard (now also the Phase 12 tables) ------------------
create or replace function public.enforce_tenant_refs()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name in ('samples', 'production', 'feeding', 'digestate', 'recipes', 'feeding_notes',
                       'shift_tasks', 'incidents', 'maintenance_plans') then
    if new.unit_id is not null
       and not exists (select 1 from public.units where id = new.unit_id and tenant_id = new.tenant_id) then
      raise exception 'unit % does not belong to tenant %', new.unit_id, new.tenant_id using errcode = '23514';
    end if;
  end if;
  if tg_table_name = 'maintenance_log' then
    if not exists (select 1 from public.maintenance_plans where id = new.plan_id and tenant_id = new.tenant_id) then
      raise exception 'maintenance plan % does not belong to tenant %', new.plan_id, new.tenant_id using errcode = '23514';
    end if;
  end if;
  if tg_table_name = 'feeding' then
    if not exists (select 1 from public.feedstocks
                    where id = new.feedstock_id and (tenant_id is null or tenant_id = new.tenant_id)) then
      raise exception 'feedstock % is not available to tenant %', new.feedstock_id, new.tenant_id using errcode = '23514';
    end if;
  end if;
  if tg_table_name = 'analyses' then
    if not exists (select 1 from public.samples where id = new.sample_id and tenant_id = new.tenant_id) then
      raise exception 'sample % does not belong to tenant %', new.sample_id, new.tenant_id using errcode = '23514';
    end if;
    if new.parameter_id is not null
       and not exists (select 1 from public.parameters
                        where id = new.parameter_id and (tenant_id is null or tenant_id = new.tenant_id)) then
      raise exception 'parameter % is not available to tenant %', new.parameter_id, new.tenant_id using errcode = '23514';
    end if;
  end if;
  if tg_table_name = 'files' then
    if new.sample_id is not null
       and not exists (select 1 from public.samples where id = new.sample_id and tenant_id = new.tenant_id) then
      raise exception 'sample % does not belong to tenant %', new.sample_id, new.tenant_id using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

-- ---- RLS, guards, audit -------------------------------------------------------
do $$
declare t text;
begin
  -- day-to-day records: read within tenant, write for admin/operator
  foreach t in array array['shift_log','shift_tasks','incidents','maintenance_log'] loop
    execute format('alter table public.%1$s enable row level security', t);
    execute format('drop policy if exists %1$s_select on public.%1$s', t);
    execute format('create policy %1$s_select on public.%1$s for select
                    using (public.is_platform_admin() or tenant_id = public.auth_tenant_id())', t);
    execute format('drop policy if exists %1$s_write on public.%1$s', t);
    execute format('create policy %1$s_write on public.%1$s for all
                    using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
                    with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))', t);
  end loop;
  -- configuration: read within tenant, write for tenant admins only
  foreach t in array array['contacts','maintenance_plans'] loop
    execute format('alter table public.%1$s enable row level security', t);
    execute format('drop policy if exists %1$s_select on public.%1$s', t);
    execute format('create policy %1$s_select on public.%1$s for select
                    using (public.is_platform_admin() or tenant_id = public.auth_tenant_id())', t);
    execute format('drop policy if exists %1$s_write on public.%1$s', t);
    execute format('create policy %1$s_write on public.%1$s for all
                    using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.is_tenant_admin()))
                    with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.is_tenant_admin()))', t);
  end loop;
  foreach t in array array['shift_tasks','incidents','maintenance_plans','maintenance_log'] loop
    execute format('drop trigger if exists tenant_refs_%1$s on public.%1$s', t);
    execute format('create trigger tenant_refs_%1$s before insert or update on public.%1$s
                    for each row execute function public.enforce_tenant_refs()', t);
  end loop;
  foreach t in array array['shift_log','shift_tasks','incidents','contacts','emergency_cards','maintenance_plans','maintenance_log'] loop
    execute format('drop trigger if exists audit_%1$s on public.%1$s', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$s
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- emergency cards: global templates readable by all, tenant overrides by its admins
alter table public.emergency_cards enable row level security;
drop policy if exists emergency_cards_select on public.emergency_cards;
create policy emergency_cards_select on public.emergency_cards for select
  using (public.is_platform_admin() or tenant_id is null or tenant_id = public.auth_tenant_id());
drop policy if exists emergency_cards_write on public.emergency_cards;
create policy emergency_cards_write on public.emergency_cards for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.is_tenant_admin()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.is_tenant_admin()));

-- ---- function exposure ---------------------------------------------------------
do $$
declare f text; r text;
begin
  foreach f in array array[
    'public.acknowledge_alert(uuid,text)',
    'public.eval_incident_alert(uuid)'
  ] loop
    execute format('revoke all on function %s from public', f);
    foreach r in array array['anon', 'authenticated'] loop
      if exists (select 1 from pg_roles where rolname = r) then
        execute format('revoke all on function %s from %I', f, r);
      end if;
    end loop;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.acknowledge_alert(uuid,text) to authenticated;
  end if;
end $$;
-- <<< END PHASE12 OBJECTS
