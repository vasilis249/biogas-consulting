-- ============================================================================
--  BioGas edition — Migration 0007
--   * Feedstock (substrate) registry
--   * Feeding log + saved recipes, with automatic OLR / HRT (view feeding_daily)
--   * Digestate log with N/P₂O₅/K₂O and Nitrates-Directive (ΖΕΝ) check
--   * Server-side alarms (state-based, de-duplicated) + e-mail recipients
--   * Hardening: cross-tenant reference checks, internal functions not callable
--  Safe to run on an existing (Phase 6) database; idempotent.
--  Fresh installs get the same objects from db/schema.sql (block below is
--  mirrored verbatim) and the reference data from db/seed.sql.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Fix (upgrade only). Global parameters (tenant_id NULL) were not
--    de-duplicated by UNIQUE (tenant_id, code) because NULLs are distinct, so
--    re-running the seed / migration 0006 could duplicate them. Re-point
--    analyses to one survivor per code, drop the rest, and switch the
--    constraint to NULLS NOT DISTINCT (PostgreSQL 15+).
-- ---------------------------------------------------------------------------
update public.analyses a
   set parameter_id = k.keep_id
  from (select id, first_value(id) over (partition by code order by created_at, id) as keep_id
          from public.parameters where tenant_id is null) k
 where a.parameter_id = k.id and k.id <> k.keep_id;

delete from public.parameters p
 using (select id, first_value(id) over (partition by code order by created_at, id) as keep_id
          from public.parameters where tenant_id is null) k
 where p.id = k.id and k.id <> k.keep_id;

alter table public.parameters drop constraint if exists parameters_tenant_id_code_key;
alter table public.parameters add constraint parameters_tenant_id_code_key
  unique nulls not distinct (tenant_id, code);

-- >>> BEGIN PHASE7 OBJECTS
-- ---------------------------------------------------------------------------
-- P7.1 Feedstock (substrate) registry. tenant_id NULL = global default.
--      bmp = biochemical methane potential, m³ CH₄ per tonne VS.
-- ---------------------------------------------------------------------------
create table if not exists public.feedstocks (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid references public.tenants (id) on delete cascade,
  name         text not null,
  category     text not null default 'other'
               check (category in ('manure','energy_crop','agro_industrial','food_waste','other')),
  ts_pct       numeric check (ts_pct is null or (ts_pct >= 0 and ts_pct <= 100)),
  vs_pct       numeric check (vs_pct is null or (vs_pct >= 0 and vs_pct <= 100)),
  bmp          numeric check (bmp is null or bmp >= 0),
  price_eur_t  numeric,                       -- negative = gate fee (income)
  cn_ratio     numeric check (cn_ratio is null or cn_ratio >= 0),
  notes        text,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  constraint feedstocks_tenant_name_key unique nulls not distinct (tenant_id, name)
);
create index if not exists idx_feedstocks_tenant on public.feedstocks (tenant_id);

-- ---------------------------------------------------------------------------
-- P7.2 Saved feeding recipes (mixes). items = [{feedstock_id, mass_t}, …]
-- ---------------------------------------------------------------------------
create table if not exists public.recipes (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  unit_id     uuid references public.units (id) on delete set null,
  name        text not null,
  items       jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array'),
  notes       text,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists idx_recipes_tenant on public.recipes (tenant_id);

-- ---------------------------------------------------------------------------
-- P7.3 Feeding log: one row per substrate, per plant, per day.
-- ---------------------------------------------------------------------------
create table if not exists public.feeding (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete cascade,
  unit_id       uuid references public.units (id) on delete set null,
  feed_date     date not null,
  feedstock_id  uuid not null references public.feedstocks (id) on delete restrict,
  mass_t        numeric not null check (mass_t >= 0),
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists idx_feeding_tenant    on public.feeding (tenant_id);
create index if not exists idx_feeding_unit_date on public.feeding (unit_id, feed_date);
create index if not exists idx_feeding_feedstock on public.feeding (feedstock_id);

-- ---------------------------------------------------------------------------
-- P7.4 Digestate log (removal / application) with nutrient content (kg/t).
-- ---------------------------------------------------------------------------
create table if not exists public.digestate (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants (id) on delete cascade,
  unit_id        uuid references public.units (id) on delete set null,
  log_date       date not null,
  mass_t         numeric check (mass_t is null or mass_t >= 0),
  destination    text not null default 'field'
                 check (destination in ('field','storage','sale','treatment','other')),
  recipient      text,
  field_area_ha  numeric check (field_area_ha is null or field_area_ha > 0),
  n_kg_t         numeric check (n_kg_t is null or n_kg_t >= 0),
  p2o5_kg_t      numeric check (p2o5_kg_t is null or p2o5_kg_t >= 0),
  k2o_kg_t       numeric check (k2o_kg_t is null or k2o_kg_t >= 0),
  notes          text,
  created_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists idx_digestate_tenant    on public.digestate (tenant_id);
create index if not exists idx_digestate_unit      on public.digestate (unit_id);
create index if not exists idx_digestate_date      on public.digestate (log_date);
create index if not exists idx_digestate_recipient on public.digestate (tenant_id, lower(recipient));

-- ---------------------------------------------------------------------------
-- P7.5 Alarms. One row per condition (dedupe_key), state-based:
--      active → (acknowledged) → resolved; re-opens if the condition returns.
--      Written only by SECURITY DEFINER triggers / RPC (no client write policy).
-- ---------------------------------------------------------------------------
create table if not exists public.alerts (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete cascade,
  unit_id          uuid references public.units (id) on delete set null,
  kind             text not null check (kind in ('parameter','production','feeding','digestate')),
  metric           text,
  value            numeric,
  severity         text not null default 'warning' check (severity in ('warning','critical')),
  message          text,
  dedupe_key       text not null unique,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  acknowledged_at  timestamptz,
  acknowledged_by  uuid references public.profiles (id) on delete set null,
  resolved_at      timestamptz,
  emailed_at       timestamptz
);
create index if not exists idx_alerts_tenant_open   on public.alerts (tenant_id) where resolved_at is null;
create index if not exists idx_alerts_pending_email on public.alerts (updated_at)
  where emailed_at is null and resolved_at is null and acknowledged_at is null;

-- ---------------------------------------------------------------------------
-- P7.6 E-mail recipients for alarm digests (sent by Edge Function send-alerts).
-- ---------------------------------------------------------------------------
create table if not exists public.alert_recipients (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete cascade,
  email         text not null check (position('@' in email) > 1),
  min_severity  text not null default 'warning' check (min_severity in ('warning','critical')),
  enabled       boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint alert_recipients_tenant_email_key unique (tenant_id, email)
);
create index if not exists idx_alert_recipients_tenant on public.alert_recipients (tenant_id);

-- ---------------------------------------------------------------------------
-- P7.7 Daily feeding summary with automatic OLR / HRT.
--      OLR = kg VS fed per m³ digester per day; HRT ≈ digester m³ / t fed per
--      day (assumes 1 t ≈ 1 m³). security_invoker → caller's RLS applies.
-- ---------------------------------------------------------------------------
create or replace view public.feeding_daily with (security_invoker = true) as
select f.tenant_id,
       f.unit_id,
       f.feed_date,
       count(*)::int as lines,
       sum(f.mass_t) as mass_t,
       sum(f.mass_t * coalesce(fs.ts_pct, 0) / 100 * coalesce(fs.vs_pct, 0) / 100) as vs_t,
       sum(f.mass_t * coalesce(fs.ts_pct, 0) / 100 * coalesce(fs.vs_pct, 0) / 100 * coalesce(fs.bmp, 0)) as ch4_expected_m3,
       sum(f.mass_t * coalesce(fs.price_eur_t, 0)) as cost_eur,
       case when max(u.digester_m3) > 0
            then sum(f.mass_t * coalesce(fs.ts_pct, 0) / 100 * coalesce(fs.vs_pct, 0) / 100) * 1000 / max(u.digester_m3)
       end as olr,
       case when max(u.digester_m3) > 0 and sum(f.mass_t) > 0
            then max(u.digester_m3) / sum(f.mass_t)
       end as hrt
  from public.feeding f
  join public.feedstocks fs on fs.id = f.feedstock_id
  left join public.units u on u.id = f.unit_id
 group by f.tenant_id, f.unit_id, f.feed_date;

-- ---------------------------------------------------------------------------
-- P7.8 Grants (Supabase grants these by default; explicit for clarity).
-- ---------------------------------------------------------------------------
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant select, insert, update, delete on public.feedstocks, public.recipes, public.feeding,
                                             public.digestate, public.alert_recipients to authenticated;
    grant select, delete on public.alerts to authenticated;
    grant select on public.feeding_daily to authenticated;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- P7.9 Row-Level Security
-- ---------------------------------------------------------------------------
alter table public.feedstocks       enable row level security;
alter table public.recipes          enable row level security;
alter table public.feeding          enable row level security;
alter table public.digestate        enable row level security;
alter table public.alerts           enable row level security;
alter table public.alert_recipients enable row level security;

-- feedstocks: global defaults readable by all; tenant rows tenant-scoped
drop policy if exists feedstocks_select on public.feedstocks;
create policy feedstocks_select on public.feedstocks for select
  using (tenant_id is null or public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists feedstocks_write on public.feedstocks;
create policy feedstocks_write on public.feedstocks for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

-- recipes / feeding / digestate: read within tenant, write for admin/operator
drop policy if exists recipes_select on public.recipes;
create policy recipes_select on public.recipes for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists recipes_write on public.recipes;
create policy recipes_write on public.recipes for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

drop policy if exists feeding_select on public.feeding;
create policy feeding_select on public.feeding for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists feeding_write on public.feeding;
create policy feeding_write on public.feeding for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

drop policy if exists digestate_select on public.digestate;
create policy digestate_select on public.digestate for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists digestate_write on public.digestate;
create policy digestate_write on public.digestate for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

-- alerts: read within tenant; delete (housekeeping) for tenant admins.
-- No INSERT/UPDATE policy on purpose: alarms come from triggers, and
-- acknowledging goes through the acknowledge_alert() RPC.
drop policy if exists alerts_select on public.alerts;
create policy alerts_select on public.alerts for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists alerts_delete on public.alerts;
create policy alerts_delete on public.alerts for delete
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'));

-- alert recipients: tenant admins (and platform admin) only
drop policy if exists alert_recipients_rw on public.alert_recipients;
create policy alert_recipients_rw on public.alert_recipients for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'));

-- ---------------------------------------------------------------------------
-- P7.10 Cross-tenant reference guard. Foreign keys ignore RLS, so without this
--       a user could attach rows to another tenant's plant / sample / substrate.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_tenant_refs()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name in ('samples', 'production', 'feeding', 'digestate', 'recipes') then
    if new.unit_id is not null
       and not exists (select 1 from public.units where id = new.unit_id and tenant_id = new.tenant_id) then
      raise exception 'unit % does not belong to tenant %', new.unit_id, new.tenant_id using errcode = '23514';
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

do $$
declare t text;
begin
  foreach t in array array['samples','analyses','production','feeding','digestate','recipes','files'] loop
    execute format('drop trigger if exists tenant_refs_%1$s on public.%1$s', t);
    execute format('create trigger tenant_refs_%1$s before insert or update on public.%1$s
                    for each row execute function public.enforce_tenant_refs()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- P7.11 Alarm engine
-- ---------------------------------------------------------------------------
-- Raise (or update / re-open) one alarm identified by p_key.
--  * still active        → refresh value / message / severity
--  * previously resolved → new occurrence: reset ack + e-mail state
--  * warning → critical  → escalation: reset ack + e-mail state
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
    emailed_at      = case when al.resolved_at is not null
                             or (al.severity = 'warning' and excluded.severity = 'critical')
                           then null else al.emailed_at end,
    resolved_at     = null;
end;
$$;

create or replace function public.clear_alert(p_key text)
returns void language sql security definer set search_path = public as $$
  update public.alerts set resolved_at = now(), updated_at = now()
   where dedupe_key = p_key and resolved_at is null;
$$;

-- Parameter alarm: evaluated on the LATEST measurement of a parameter at a plant.
-- warning = outside the ideal band; critical = beyond it by > 20 % of the band.
create or replace function public.eval_param_alert(p_tenant uuid, p_unit uuid, p_param uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_key   text;
  a       record;
  p       record;
  v_span  numeric;
  v_sev   text;
  v_uname text;
begin
  if p_tenant is null or p_param is null then return; end if;
  v_key := 'param:' || p_tenant || ':' || coalesce(p_unit::text, 'none') || ':' || p_param;

  select an.value, an.unit as munit, s.code as scode
    into a
    from public.analyses an
    join public.samples s on s.id = an.sample_id
   where an.tenant_id = p_tenant
     and an.parameter_id = p_param
     and s.unit_id is not distinct from p_unit
   order by coalesce(an.measured_at, an.created_at) desc, an.created_at desc
   limit 1;
  if not found or a.value is null then perform public.clear_alert(v_key); return; end if;

  select * into p from public.parameters where id = p_param;
  if not found or (p.ideal_min is null and p.ideal_max is null) then
    perform public.clear_alert(v_key); return;
  end if;

  if (p.ideal_min is not null and a.value < p.ideal_min) or (p.ideal_max is not null and a.value > p.ideal_max) then
    v_span := p.ideal_max - p.ideal_min;
    if v_span is null or v_span <= 0 then v_span := greatest(abs(coalesce(p.ideal_max, p.ideal_min)), 1); end if;
    v_sev := case when (p.ideal_min is not null and a.value < p.ideal_min - 0.2 * v_span)
                    or (p.ideal_max is not null and a.value > p.ideal_max + 0.2 * v_span)
                  then 'critical' else 'warning' end;
    select name into v_uname from public.units where id = p_unit;
    perform public.raise_alert(p_tenant, p_unit, 'parameter', coalesce(p.label_el, p.code), a.value, v_sev,
      format('%s = %s%s εκτός ορίων [%s – %s] · %s · δείγμα %s',
             coalesce(p.label_el, p.code), a.value::text, coalesce(' ' || nullif(a.munit, ''), ''),
             coalesce(p.ideal_min::text, '−∞'), coalesce(p.ideal_max::text, '+∞'),
             coalesce(v_uname, '—'), coalesce(a.scode, '—')),
      v_key);
  else
    perform public.clear_alert(v_key);
  end if;
end;
$$;

-- Production alarms on the latest daily log of a plant.
create or replace function public.eval_production_alerts(p_tenant uuid, p_unit uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  k_ch4   text;
  k_chp   text;
  r       record;
  v_uname text;
begin
  if p_tenant is null then return; end if;
  k_ch4 := 'prod-ch4:' || p_tenant || ':' || coalesce(p_unit::text, 'none');
  k_chp := 'prod-chp:' || p_tenant || ':' || coalesce(p_unit::text, 'none');

  select * into r from public.production
   where tenant_id = p_tenant and unit_id is not distinct from p_unit
   order by log_date desc, created_at desc
   limit 1;
  if not found then
    perform public.clear_alert(k_ch4); perform public.clear_alert(k_chp); return;
  end if;
  select name into v_uname from public.units where id = p_unit;

  if r.ch4_pct is not null and r.ch4_pct < 50 then
    perform public.raise_alert(p_tenant, p_unit, 'production', 'CH₄ %', r.ch4_pct,
      case when r.ch4_pct < 45 then 'critical' else 'warning' end,
      format('Χαμηλό μεθάνιο %s%% στο βιοαέριο · %s · %s', r.ch4_pct, coalesce(v_uname, '—'), to_char(r.log_date, 'DD/MM/YYYY')),
      k_ch4);
  else
    perform public.clear_alert(k_ch4);
  end if;

  if r.chp_hours is not null and r.chp_hours < 20 then
    perform public.raise_alert(p_tenant, p_unit, 'production', 'Ώρες ΣΗΘ', r.chp_hours,
      case when r.chp_hours < 16 then 'critical' else 'warning' end,
      format('Χαμηλή διαθεσιμότητα ΣΗΘ: %s ώρες (%s%%) · %s · %s', r.chp_hours, round(r.chp_hours / 24 * 100),
             coalesce(v_uname, '—'), to_char(r.log_date, 'DD/MM/YYYY')),
      k_chp);
  else
    perform public.clear_alert(k_chp);
  end if;
end;
$$;

-- Feeding alarms (OLR / HRT) on the latest feeding day of a plant.
create or replace function public.eval_feeding_alerts(p_tenant uuid, p_unit uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  k_olr  text;
  k_hrt  text;
  v_date date;
  r      record;
  v_olr  numeric;
  v_hrt  numeric;
begin
  if p_tenant is null then return; end if;
  k_olr := 'olr:' || p_tenant || ':' || coalesce(p_unit::text, 'none');
  k_hrt := 'hrt:' || p_tenant || ':' || coalesce(p_unit::text, 'none');
  if p_unit is null then
    perform public.clear_alert(k_olr); perform public.clear_alert(k_hrt); return;
  end if;

  select max(feed_date) into v_date from public.feeding where tenant_id = p_tenant and unit_id = p_unit;
  if v_date is null then
    perform public.clear_alert(k_olr); perform public.clear_alert(k_hrt); return;
  end if;

  select u.name as uname,
         u.digester_m3 as vol,
         sum(f.mass_t) as mass_t,
         sum(f.mass_t * coalesce(fs.ts_pct, 0) / 100 * coalesce(fs.vs_pct, 0) / 100) as vs_t
    into r
    from public.feeding f
    join public.feedstocks fs on fs.id = f.feedstock_id
    join public.units u on u.id = f.unit_id
   where f.tenant_id = p_tenant and f.unit_id = p_unit and f.feed_date = v_date
   group by u.name, u.digester_m3;
  if not found or r.vol is null or r.vol <= 0 then
    perform public.clear_alert(k_olr); perform public.clear_alert(k_hrt); return;
  end if;

  v_olr := r.vs_t * 1000 / r.vol;
  v_hrt := case when r.mass_t > 0 then r.vol / r.mass_t end;

  if v_olr > 4 then
    perform public.raise_alert(p_tenant, p_unit, 'feeding', 'OLR', round(v_olr, 2),
      case when v_olr > 5 then 'critical' else 'warning' end,
      format('Υψηλό οργανικό φορτίο OLR %s kg VS/m³·d (όριο 4) · %s · %s', round(v_olr, 2), r.uname, to_char(v_date, 'DD/MM/YYYY')),
      k_olr);
  else
    perform public.clear_alert(k_olr);
  end if;

  if v_hrt is not null and v_hrt < 20 then
    perform public.raise_alert(p_tenant, p_unit, 'feeding', 'HRT', round(v_hrt, 1),
      case when v_hrt < 15 then 'critical' else 'warning' end,
      format('Μικρός χρόνος παραμονής HRT %s ημέρες (ελάχ. 20) · %s · %s', round(v_hrt, 1), r.uname, to_char(v_date, 'DD/MM/YYYY')),
      k_hrt);
  else
    perform public.clear_alert(k_hrt);
  end if;
end;
$$;

-- Digestate: cumulative N applied per recipient per calendar year vs the
-- Nitrates Directive limit for vulnerable zones (ΖΕΝ), 170 kg N/ha/yr.
-- Field area = largest area declared for that recipient in the year.
create or replace function public.eval_digestate_alert(p_tenant uuid, p_recipient text, p_year integer)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_rec   text := lower(btrim(coalesce(p_recipient, '')));
  v_key   text;
  r       record;
  v_nha   numeric;
  v_limit constant numeric := 170;
begin
  if p_tenant is null or v_rec = '' or p_year is null then return; end if;
  v_key := 'dig-n:' || p_tenant || ':' || v_rec || ':' || p_year;

  select sum(coalesce(mass_t, 0) * coalesce(n_kg_t, 0)) as n_kg, max(field_area_ha) as area
    into r
    from public.digestate
   where tenant_id = p_tenant and destination = 'field'
     and lower(btrim(coalesce(recipient, ''))) = v_rec
     and extract(year from log_date) = p_year;
  if r.area is null or r.area <= 0 or coalesce(r.n_kg, 0) <= 0 then
    perform public.clear_alert(v_key); return;
  end if;

  v_nha := r.n_kg / r.area;
  if v_nha >= v_limit * 0.9 then
    perform public.raise_alert(p_tenant, null, 'digestate', 'kg N/ha', round(v_nha, 1),
      case when v_nha > v_limit then 'critical' else 'warning' end,
      format('Άζωτο από χώνευμα %s kg N/ha το %s για «%s» (όριο ΖΕΝ %s kg N/ha/έτος)',
             round(v_nha, 1), p_year, btrim(p_recipient), v_limit),
      v_key);
  else
    perform public.clear_alert(v_key);
  end if;
end;
$$;

-- Re-evaluate every alarm (after upgrades / bulk imports).
create or replace function public.reevaluate_alerts(p_tenant uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select distinct an.tenant_id, s.unit_id, an.parameter_id
             from public.analyses an join public.samples s on s.id = an.sample_id
            where an.parameter_id is not null and (p_tenant is null or an.tenant_id = p_tenant)
  loop perform public.eval_param_alert(r.tenant_id, r.unit_id, r.parameter_id); n := n + 1; end loop;

  for r in select distinct tenant_id, unit_id from public.production
            where p_tenant is null or tenant_id = p_tenant
  loop perform public.eval_production_alerts(r.tenant_id, r.unit_id); n := n + 1; end loop;

  for r in select distinct tenant_id, unit_id from public.feeding
            where p_tenant is null or tenant_id = p_tenant
  loop perform public.eval_feeding_alerts(r.tenant_id, r.unit_id); n := n + 1; end loop;

  for r in select tenant_id, min(btrim(recipient)) as rec, extract(year from log_date)::int as yr
             from public.digestate
            where destination = 'field' and btrim(coalesce(recipient, '')) <> ''
              and (p_tenant is null or tenant_id = p_tenant)
            group by tenant_id, lower(btrim(recipient)), extract(year from log_date)
  loop perform public.eval_digestate_alert(r.tenant_id, r.rec, r.yr); n := n + 1; end loop;
  return n;
end;
$$;

-- Acknowledge an alarm (the only client write path into alerts).
create or replace function public.acknowledge_alert(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.alerts where id = p_id;
  if not found then raise exception 'alert not found' using errcode = 'P0002'; end if;
  if not (public.is_platform_admin() or (v_tenant = public.auth_tenant_id() and public.can_write())) then
    raise exception 'not allowed to acknowledge this alert' using errcode = '42501';
  end if;
  update public.alerts set acknowledged_at = now(), acknowledged_by = auth.uid(), updated_at = now()
   where id = p_id;
end;
$$;

-- Replace one plant's feeding for one day atomically. SECURITY INVOKER:
-- the caller's RLS decides what may be deleted / inserted.
create or replace function public.replace_feeding(p_tenant uuid, p_unit uuid, p_date date, p_items jsonb)
returns integer language plpgsql security invoker set search_path = public as $$
declare v_ids uuid[]; v_visible integer; v_n integer;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a JSON array' using errcode = '22023';
  end if;
  perform 1 from public.units where id = p_unit and tenant_id = p_tenant;
  if not found then raise exception 'unknown plant' using errcode = '23503'; end if;
  select array_agg(distinct (e->>'feedstock_id')::uuid) into v_ids
    from jsonb_array_elements(p_items) e
   where coalesce((e->>'mass_t')::numeric, 0) > 0;
  if v_ids is not null then
    select count(*) into v_visible from public.feedstocks where id = any (v_ids);
    if v_visible <> cardinality(v_ids) then raise exception 'unknown feedstock' using errcode = '23503'; end if;
  end if;
  delete from public.feeding where tenant_id = p_tenant and unit_id = p_unit and feed_date = p_date;
  insert into public.feeding (tenant_id, unit_id, feed_date, feedstock_id, mass_t, created_by)
  select p_tenant, p_unit, p_date, (e->>'feedstock_id')::uuid, (e->>'mass_t')::numeric, auth.uid()
    from jsonb_array_elements(p_items) e
   where coalesce((e->>'mass_t')::numeric, 0) > 0;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- P7.12 Alarm triggers
-- ---------------------------------------------------------------------------
create or replace function public.trg_analyses_alarm()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_unit uuid;
begin
  if tg_op <> 'DELETE' then
    select unit_id into v_unit from public.samples where id = new.sample_id;
    perform public.eval_param_alert(new.tenant_id, v_unit, new.parameter_id);
  end if;
  if tg_op = 'DELETE' then
    select unit_id into v_unit from public.samples where id = old.sample_id;
    perform public.eval_param_alert(old.tenant_id, v_unit, old.parameter_id);
  elsif tg_op = 'UPDATE' then
    if old.parameter_id is distinct from new.parameter_id
       or old.sample_id is distinct from new.sample_id
       or old.tenant_id is distinct from new.tenant_id then
      select unit_id into v_unit from public.samples where id = old.sample_id;
      perform public.eval_param_alert(old.tenant_id, v_unit, old.parameter_id);
    end if;
  end if;
  return null;
end;
$$;

create or replace function public.trg_samples_alarm()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if tg_op = 'DELETE' then
    for r in select id from public.parameters where tenant_id is null or tenant_id = old.tenant_id loop
      perform public.eval_param_alert(old.tenant_id, old.unit_id, r.id);
    end loop;
  elsif tg_op = 'UPDATE' and old.unit_id is distinct from new.unit_id then
    for r in select distinct parameter_id from public.analyses where sample_id = new.id and parameter_id is not null loop
      perform public.eval_param_alert(new.tenant_id, old.unit_id, r.parameter_id);
      perform public.eval_param_alert(new.tenant_id, new.unit_id, r.parameter_id);
    end loop;
  end if;
  return null;
end;
$$;

create or replace function public.trg_production_alarm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op <> 'DELETE' then perform public.eval_production_alerts(new.tenant_id, new.unit_id); end if;
  if tg_op = 'DELETE' then
    perform public.eval_production_alerts(old.tenant_id, old.unit_id);
  elsif tg_op = 'UPDATE' then
    if old.unit_id is distinct from new.unit_id or old.tenant_id is distinct from new.tenant_id then
      perform public.eval_production_alerts(old.tenant_id, old.unit_id);
    end if;
  end if;
  return null;
end;
$$;

create or replace function public.trg_feeding_alarm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op <> 'DELETE' then perform public.eval_feeding_alerts(new.tenant_id, new.unit_id); end if;
  if tg_op = 'DELETE' then
    perform public.eval_feeding_alerts(old.tenant_id, old.unit_id);
  elsif tg_op = 'UPDATE' then
    if old.unit_id is distinct from new.unit_id or old.tenant_id is distinct from new.tenant_id then
      perform public.eval_feeding_alerts(old.tenant_id, old.unit_id);
    end if;
  end if;
  return null;
end;
$$;

create or replace function public.trg_digestate_alarm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op <> 'DELETE' then
    perform public.eval_digestate_alert(new.tenant_id, new.recipient, extract(year from new.log_date)::int);
  end if;
  if tg_op = 'DELETE' then
    perform public.eval_digestate_alert(old.tenant_id, old.recipient, extract(year from old.log_date)::int);
  elsif tg_op = 'UPDATE' then
    if lower(btrim(coalesce(old.recipient, ''))) is distinct from lower(btrim(coalesce(new.recipient, '')))
       or extract(year from old.log_date) is distinct from extract(year from new.log_date)
       or old.tenant_id is distinct from new.tenant_id then
      perform public.eval_digestate_alert(old.tenant_id, old.recipient, extract(year from old.log_date)::int);
    end if;
  end if;
  return null;
end;
$$;

-- A plant's digester volume changes its OLR / HRT.
create or replace function public.trg_units_alarm()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.eval_feeding_alerts(new.tenant_id, new.id);
  return null;
end;
$$;

-- A substrate's TS / VS changes the OLR of every plant that uses it.
create or replace function public.trg_feedstocks_alarm()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select distinct tenant_id, unit_id from public.feeding
            where feedstock_id = new.id and unit_id is not null loop
    perform public.eval_feeding_alerts(r.tenant_id, r.unit_id);
  end loop;
  return null;
end;
$$;

drop trigger if exists alarm_analyses on public.analyses;
create trigger alarm_analyses after insert or update or delete on public.analyses
  for each row execute function public.trg_analyses_alarm();
drop trigger if exists alarm_samples on public.samples;
create trigger alarm_samples after update of unit_id or delete on public.samples
  for each row execute function public.trg_samples_alarm();
drop trigger if exists alarm_production on public.production;
create trigger alarm_production after insert or update or delete on public.production
  for each row execute function public.trg_production_alarm();
drop trigger if exists alarm_feeding on public.feeding;
create trigger alarm_feeding after insert or update or delete on public.feeding
  for each row execute function public.trg_feeding_alarm();
drop trigger if exists alarm_digestate on public.digestate;
create trigger alarm_digestate after insert or update or delete on public.digestate
  for each row execute function public.trg_digestate_alarm();
drop trigger if exists alarm_units on public.units;
create trigger alarm_units after update of digester_m3 on public.units
  for each row execute function public.trg_units_alarm();
drop trigger if exists alarm_feedstocks on public.feedstocks;
create trigger alarm_feedstocks after update of ts_pct, vs_pct on public.feedstocks
  for each row execute function public.trg_feedstocks_alarm();

-- Audit the new business tables (alerts themselves are not audited).
do $$
declare t text;
begin
  foreach t in array array['feedstocks','recipes','feeding','digestate','alert_recipients'] loop
    execute format('drop trigger if exists audit_%1$s on public.%1$s', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$s
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- P7.13 Internal functions must not be callable through the API (PostgREST
--       exposes public functions). Only acknowledge_alert / replace_feeding
--       are client-facing.
-- ---------------------------------------------------------------------------
do $$
declare f text; r text;
begin
  foreach f in array array[
    'public.raise_alert(uuid,uuid,text,text,numeric,text,text,text)',
    'public.clear_alert(text)',
    'public.eval_param_alert(uuid,uuid,uuid)',
    'public.eval_production_alerts(uuid,uuid)',
    'public.eval_feeding_alerts(uuid,uuid)',
    'public.eval_digestate_alert(uuid,text,integer)',
    'public.reevaluate_alerts(uuid)',
    'public.acknowledge_alert(uuid)',
    'public.replace_feeding(uuid,uuid,date,jsonb)'
  ] loop
    execute format('revoke all on function %s from public', f);
    foreach r in array array['anon', 'authenticated'] loop
      if exists (select 1 from pg_roles where rolname = r) then
        execute format('revoke all on function %s from %I', f, r);
      end if;
    end loop;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function public.acknowledge_alert(uuid) to authenticated;
    grant execute on function public.replace_feeding(uuid,uuid,date,jsonb) to authenticated;
  end if;
end $$;
-- <<< END PHASE7 OBJECTS

-- ---------------------------------------------------------------------------
-- Reference data for existing databases (fresh installs: db/seed.sql)
-- ---------------------------------------------------------------------------
insert into public.parameters (tenant_id, code, label_el, label_en, default_unit, ideal_min, ideal_max, sort_order) values
  (null, 'dig_n',    'Ολικό άζωτο χωνεύματος (N)',   'Digestate total N', 'kg/t', null, null, 120),
  (null, 'dig_p2o5', 'Φώσφορος χωνεύματος (P₂O₅)',   'Digestate P₂O₅',    'kg/t', null, null, 130),
  (null, 'dig_k2o',  'Κάλιο χωνεύματος (K₂O)',       'Digestate K₂O',     'kg/t', null, null, 140)
on conflict (tenant_id, code) do nothing;

insert into public.feedstocks (tenant_id, name, category, ts_pct, vs_pct, bmp, price_eur_t, cn_ratio, notes) values
  (null, 'Υγρή κοπριά βοοειδών',              'manure',           8, 80, 210,   0,  10, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Στερεή κοπριά βοοειδών',             'manure',          22, 80, 230,   0,  18, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Υγρή κοπριά χοίρων',                 'manure',           5, 75, 300,   0,   8, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Κοπριά πουλερικών',                  'manure',          40, 75, 280,   5,   8, 'Ενδεικτικές τιμές βιβλιογραφίας — υψηλό N, προσοχή στην αμμωνία'),
  (null, 'Ενσίρωμα αραβοσίτου',                'energy_crop',     33, 95, 340,  40,  40, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Ενσίρωμα χόρτου / τριφυλλιού',       'energy_crop',     30, 90, 300,  30,  20, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Τυρόγαλα (ορός γάλακτος)',           'agro_industrial',  6, 85, 450,   0,  15, 'Ταχεία οξίνιση — δοσολογία σταδιακά'),
  (null, 'Κατσίγαρος (απόνερα ελαιοτριβείου)', 'agro_industrial', 10, 80, 400,   0,  30, 'Πολυφαινόλες — περιορισμένο ποσοστό στο μίγμα'),
  (null, 'Ελαιοπυρήνας (υγρός, 2 φάσεων)',     'agro_industrial', 30, 90, 330,   0,  45, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Φλούδες εσπεριδοειδών',              'agro_industrial', 20, 95, 380,   0,  30, 'Λιμονένιο — περιορισμένο ποσοστό στο μίγμα'),
  (null, 'Περιεχόμενο στομάχων (σφαγεία)',     'agro_industrial', 15, 85, 350, -10,  20, 'Αρνητική τιμή = έσοδο (gate fee)'),
  (null, 'Απόβλητα τροφίμων / εστίασης',       'food_waste',      25, 90, 450, -20,  18, 'Αρνητική τιμή = έσοδο (gate fee) — απαιτείται υγιεινοποίηση'),
  (null, 'Ακατέργαστη γλυκερίνη',              'other',           80, 95, 450,  50, 150, 'Πολύ υψηλή απόδοση — μικρό ποσοστό (≤5%)')
on conflict (tenant_id, name) do nothing;

-- Raise alarms for data that already exists.
select public.reevaluate_alerts();

-- ============================================================================
--  End migration 0007.
-- ============================================================================
