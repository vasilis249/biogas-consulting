-- ============================================================================
--  LabPortal — Multi-tenant schema for an agronomy / lab-analysis platform
--  Target: Supabase (PostgreSQL + Auth + Storage + RLS)
--
--  Original work. Designed from general domain concepts (samples, analyses,
--  NPK/pH/EC, units, reports) — not derived from any third-party codebase.
--
--  Tenancy model: ONE app, many client organisations ("tenants").
--  Every business row carries tenant_id and is isolated with Row-Level
--  Security. The platform owner (you) is flagged is_platform_admin and sees
--  everything; each tenant's users only ever see their own tenant's rows.
--
--  Run order: this whole file is idempotent-ish for a fresh project. For an
--  existing project, split into numbered migrations instead.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------------
create extension if not exists "pgcrypto";        -- gen_random_uuid()

-- ---------------------------------------------------------------------------
-- 1. Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.user_role as enum ('admin', 'operator', 'viewer');
exception when duplicate_object then null; end $$;

do $$ begin
  -- What kind of sample was taken (extend freely per your lab's scope).
  create type public.sample_kind as enum
    ('leaf', 'soil', 'water', 'reservoir', 'fruit', 'substrate', 'other',
     'digester', 'substrate_in', 'digestate', 'biogas', 'influent', 'effluent');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.sample_status as enum ('draft', 'received', 'analyzing', 'done', 'archived');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 2. Core tenancy tables
-- ---------------------------------------------------------------------------

-- Your customers. Each row = one client organisation you serve.
create table if not exists public.tenants (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null unique,
  status      text not null default 'active',   -- active | suspended
  settings    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- One profile per Supabase auth user. tenant_id = which client they belong to.
-- Platform staff (you) have is_platform_admin = true and tenant_id = null.
create table if not exists public.profiles (
  id                 uuid primary key references auth.users (id) on delete cascade,
  tenant_id          uuid references public.tenants (id) on delete set null,
  full_name          text,
  email              text,
  role               public.user_role not null default 'viewer',
  is_platform_admin  boolean not null default false,
  last_seen          timestamptz,
  created_at         timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3. Domain tables (all tenant-scoped)
-- ---------------------------------------------------------------------------

-- Plants / digesters belonging to a tenant (a biogas μονάδα / χωνευτής).
create table if not exists public.units (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  name        text not null,
  location    text,
  notes       text,
  capacity_kw numeric,                          -- CHP electrical capacity (kWel)
  digester_m3 numeric,                          -- active digester volume (m³)
  created_at  timestamptz not null default now()
);

-- Daily production / operation log per plant (biogas edition).
create table if not exists public.production (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  unit_id      uuid references public.units (id) on delete set null,
  log_date     date not null,
  feedstock_t  numeric,
  biogas_m3    numeric,
  ch4_pct      numeric,
  kwh_el       numeric,
  kwh_th       numeric,
  chp_hours    numeric,
  flare_hours  numeric,
  notes        text,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);

-- Catalogue of measurable parameters, with optional ideal range.
-- tenant_id null = a global default available to everyone; a tenant may add
-- its own parameters on top.
create table if not exists public.parameters (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references public.tenants (id) on delete cascade,
  code          text not null,                 -- 'ph', 'ec', 'n', 'p', 'k', ...
  label_el      text,
  label_en      text,
  default_unit  text,                          -- 'mg/kg', 'mg/l', 'mmol/l', ...
  ideal_min     numeric,
  ideal_max     numeric,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now(),
  unique nulls not distinct (tenant_id, code)   -- global (NULL) rows deduplicated too
);

-- A physical sample taken from a unit.
create table if not exists public.samples (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  unit_id     uuid references public.units (id) on delete set null,
  code        text,                            -- human-friendly sample code
  kind        public.sample_kind not null default 'leaf',
  status      public.sample_status not null default 'draft',
  taken_at    date,
  taken_by    text,
  notes       text,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);

-- Individual measurements for a sample (EAV so the parameter set is flexible).
create table if not exists public.analyses (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete cascade,
  sample_id     uuid not null references public.samples (id) on delete cascade,
  parameter_id  uuid references public.parameters (id) on delete set null,
  value         numeric,
  unit          text,
  measured_at   timestamptz,
  method        text,
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now()
);

-- File attachments (actual bytes live in a Supabase Storage bucket; this
-- table only holds metadata + the storage path).
create table if not exists public.files (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  sample_id    uuid references public.samples (id) on delete cascade,
  storage_path text not null,
  filename     text,
  mime         text,
  size_bytes   bigint,
  uploaded_by  uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);

-- Lightweight financials module (Οικονομικά) — optional, MVP-light.
create table if not exists public.invoices (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  period      text,                            -- 'YYYY-MM'
  amount      numeric(12,2) not null default 0,
  currency    text not null default 'EUR',
  status      text not null default 'draft',   -- draft | issued | paid
  issued_at   date,
  notes       text,
  created_at  timestamptz not null default now()
);

-- Audit trail for admin visibility + security.
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  tenant_id   uuid references public.tenants (id) on delete cascade,
  user_id     uuid references public.profiles (id) on delete set null,
  action      text not null,                   -- 'insert' | 'update' | 'delete' | 'login' ...
  entity      text,
  entity_id   uuid,
  meta        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- Invitations: pre-authorise an email for a tenant+role; the signup trigger
-- auto-assigns the person when they register.
create table if not exists public.invitations (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  email       text not null,
  role        public.user_role not null default 'operator',
  invited_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  accepted_at timestamptz
);

-- ---------------------------------------------------------------------------
-- 4. Indexes
-- ---------------------------------------------------------------------------
create index if not exists idx_profiles_tenant   on public.profiles (tenant_id);
create index if not exists idx_units_tenant       on public.units (tenant_id);
create index if not exists idx_parameters_tenant  on public.parameters (tenant_id);
create index if not exists idx_samples_tenant      on public.samples (tenant_id);
create index if not exists idx_samples_unit        on public.samples (unit_id);
create index if not exists idx_samples_taken_at    on public.samples (taken_at);
create index if not exists idx_analyses_tenant     on public.analyses (tenant_id);
create index if not exists idx_analyses_sample     on public.analyses (sample_id);
create index if not exists idx_files_tenant        on public.files (tenant_id);
create index if not exists idx_files_sample        on public.files (sample_id);
create index if not exists idx_invoices_tenant     on public.invoices (tenant_id);
create index if not exists idx_audit_tenant        on public.audit_log (tenant_id);
create index if not exists idx_invitations_email   on public.invitations (lower(email));
create index if not exists idx_invitations_tenant  on public.invitations (tenant_id);
create index if not exists idx_production_tenant    on public.production (tenant_id);
create index if not exists idx_production_unit       on public.production (unit_id);
create index if not exists idx_production_date       on public.production (log_date);

-- ---------------------------------------------------------------------------
-- 5. Helper functions (SECURITY DEFINER to avoid RLS recursion on profiles)
-- ---------------------------------------------------------------------------
create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_platform_admin from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.auth_tenant_id()
returns uuid language sql stable security definer set search_path = public as $$
  select tenant_id from public.profiles where id = auth.uid();
$$;

create or replace function public.auth_role()
returns public.user_role language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;

-- Can the current user write (insert/update/delete) within their tenant?
create or replace function public.can_write()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_platform_admin()
      or public.auth_role() in ('admin', 'operator');
$$;

-- ---------------------------------------------------------------------------
-- 6. Auto-provision a profile when a new auth user signs up
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare inv public.invitations;
begin
  -- consume a matching pending invitation, if any
  select * into inv from public.invitations
   where lower(email) = lower(new.email) and accepted_at is null
   order by created_at desc limit 1;

  insert into public.profiles (id, email, full_name, tenant_id, role)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'full_name', new.email),
          inv.tenant_id, coalesce(inv.role, 'viewer'::public.user_role))
  on conflict (id) do nothing;

  if inv.id is not null then
    update public.invitations set accepted_at = now() where id = inv.id;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Audit: generic trigger logs insert/update/delete on key tables.
create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_id uuid;
begin
  if (tg_op = 'UPDATE' and tg_table_name = 'profiles') then
    if (to_jsonb(new) - 'last_seen') = (to_jsonb(old) - 'last_seen') then
      return new;   -- heartbeat-only update → do not log
    end if;
  end if;
  if (tg_op = 'DELETE') then v_tenant := old.tenant_id; v_id := old.id;
  else                       v_tenant := new.tenant_id; v_id := new.id; end if;
  insert into public.audit_log (tenant_id, user_id, action, entity, entity_id, meta)
  values (v_tenant, auth.uid(), lower(tg_op), tg_table_name, v_id,
          jsonb_build_object('ts', now()));
  return coalesce(new, old);
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['units','parameters','samples','analyses','invoices','profiles','files','production']
  loop
    execute format('drop trigger if exists audit_%1$s on public.%1$s', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$s
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Row-Level Security
-- ---------------------------------------------------------------------------
alter table public.tenants     enable row level security;
alter table public.profiles    enable row level security;
alter table public.units       enable row level security;
alter table public.parameters  enable row level security;
alter table public.samples     enable row level security;
alter table public.analyses    enable row level security;
alter table public.files       enable row level security;
alter table public.invitations enable row level security;
alter table public.production  enable row level security;
alter table public.invoices    enable row level security;
alter table public.audit_log   enable row level security;

-- ---- tenants: platform admin manages; a user can read their own tenant -----
drop policy if exists tenants_select on public.tenants;
create policy tenants_select on public.tenants for select
  using (public.is_platform_admin() or id = public.auth_tenant_id());

drop policy if exists tenants_write on public.tenants;
create policy tenants_write on public.tenants for all
  using (public.is_platform_admin())
  with check (public.is_platform_admin());

-- ---- profiles --------------------------------------------------------------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (
    id = auth.uid()
    or public.is_platform_admin()
    or tenant_id = public.auth_tenant_id()
  );

-- A user may edit their own profile; a tenant admin may edit their tenant's.
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update
  using (
    id = auth.uid()
    or public.is_platform_admin()
    or (public.auth_role() = 'admin' and tenant_id = public.auth_tenant_id())
  )
  with check (
    id = auth.uid()
    or public.is_platform_admin()
    or (public.auth_role() = 'admin' and tenant_id = public.auth_tenant_id())
  );

-- Inserts normally happen via the signup trigger / platform admin only.
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert
  with check (public.is_platform_admin() or id = auth.uid());

-- ---- generic tenant-scoped policy, applied to each business table ----------
-- Pattern: read within tenant; write within tenant only for admin/operator.

-- units
drop policy if exists units_select on public.units;
create policy units_select on public.units for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists units_write on public.units;
create policy units_write on public.units for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

-- parameters (global defaults readable by all; tenant rows tenant-scoped)
drop policy if exists parameters_select on public.parameters;
create policy parameters_select on public.parameters for select
  using (tenant_id is null or public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists parameters_write on public.parameters;
create policy parameters_write on public.parameters for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

-- samples
drop policy if exists samples_select on public.samples;
create policy samples_select on public.samples for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists samples_write on public.samples;
create policy samples_write on public.samples for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

-- analyses
drop policy if exists analyses_select on public.analyses;
create policy analyses_select on public.analyses for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists analyses_write on public.analyses;
create policy analyses_write on public.analyses for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

-- files
drop policy if exists files_select on public.files;
create policy files_select on public.files for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists files_write on public.files;
create policy files_write on public.files for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

-- invoices (financials: read within tenant, write admin-only is stricter —
-- here operators can edit too; tighten to admin if you prefer)
drop policy if exists invoices_select on public.invoices;
create policy invoices_select on public.invoices for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists invoices_write on public.invoices;
create policy invoices_write on public.invoices for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'));

-- audit_log (read within tenant for admins; inserts allowed for any member)
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'));
drop policy if exists audit_insert on public.audit_log;
create policy audit_insert on public.audit_log for insert
  with check (public.is_platform_admin() or tenant_id = public.auth_tenant_id());

-- invitations (platform admin, or the tenant's own admin, manage them)
-- production (read within tenant; write for admin/operator)
drop policy if exists production_select on public.production;
create policy production_select on public.production for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists production_write on public.production;
create policy production_write on public.production for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

drop policy if exists invitations_rw on public.invitations;
create policy invitations_rw on public.invitations for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'));

-- ============================================================================
--  Phase 7 (BioGas): feedstocks, recipes, feeding + OLR/HRT, digestate, alarms.
--  Mirrored verbatim from db/migrations/0007 (keep in sync via markers).
-- ============================================================================
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

-- Phase 9 — RED III sustainability config (kept verbatim with migration 0009
-- so a fresh install equals an upgraded one).
-- >>> BEGIN PHASE9 OBJECTS
alter table public.units add column if not exists commissioning_date    date;
alter table public.units add column if not exists rated_thermal_input_mw numeric;
alter table public.units add column if not exists red_case              smallint not null default 1;
alter table public.units add column if not exists digestate_storage     text     not null default 'open';
alter table public.units add column if not exists red_product           text     not null default 'electricity';
alter table public.units add column if not exists offgas_combustion     boolean  not null default false;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'units_red_case_check' and conrelid = 'public.units'::regclass) then
    alter table public.units add constraint units_red_case_check check (red_case between 1 and 3);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'units_digestate_storage_check' and conrelid = 'public.units'::regclass) then
    alter table public.units add constraint units_digestate_storage_check check (digestate_storage in ('open','close'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'units_red_product_check' and conrelid = 'public.units'::regclass) then
    alter table public.units add constraint units_red_product_check check (red_product in ('electricity','transport'));
  end if;
end $$;

alter table public.feedstocks add column if not exists red_class text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'feedstocks_red_class_check' and conrelid = 'public.feedstocks'::regclass) then
    alter table public.feedstocks add constraint feedstocks_red_class_check check (red_class in ('manure','maize','biowaste','other'));
  end if;
end $$;

-- Map the operational category to a RED III default-value class for existing
-- rows (operators can override per feedstock afterwards). Only fills nulls.
update public.feedstocks set red_class = case category
  when 'manure'      then 'manure'
  when 'energy_crop' then 'maize'
  when 'food_waste'  then 'biowaste'
  else 'other'
end where red_class is null;
-- <<< END PHASE9 OBJECTS

-- Phase 10 — operator-review P1 fixes: one production log per digester/day,
-- physical range checks, admin-only plant setup & alarm limits (kept verbatim
-- with migration 0010 so a fresh install equals an upgraded one).
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

-- Phase 11 — trend alarms, daily digester temperature, planned CHP stop,
-- feeding notes (kept verbatim with migration 0011).
-- >>> BEGIN PHASE11 OBJECTS
-- ---- parameters: configurable trend alarm ---------------------------------
alter table public.parameters add column if not exists trend_delta numeric;
alter table public.parameters add column if not exists trend_days  integer;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'parameters_trend_days_check' and conrelid = 'public.parameters'::regclass) then
    alter table public.parameters add constraint parameters_trend_days_check check (trend_days is null or trend_days between 1 and 90);
  end if;
end $$;
-- FOS/TAC +0.05 within two weeks (operator review §8). Fills only unset rows.
update public.parameters set trend_delta = 0.05, trend_days = 14
 where tenant_id is null and code = 'fos_tac' and trend_delta is null and trend_days is null;

-- ---- production: daily operator readings ------------------------------------
alter table public.production add column if not exists digester_temp_c numeric;
alter table public.production add column if not exists planned_stop    boolean not null default false;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'production_digester_temp_check' and conrelid = 'public.production'::regclass) then
    alter table public.production add constraint production_digester_temp_check
      check (digester_temp_c is null or (digester_temp_c >= 0 and digester_temp_c <= 80));
  end if;
end $$;

-- ---- feeding_notes: why the ration changed ---------------------------------
create table if not exists public.feeding_notes (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  unit_id     uuid not null references public.units (id) on delete cascade,
  feed_date   date not null,
  note        text not null check (btrim(note) <> ''),
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  constraint feeding_notes_unit_day_key unique (unit_id, feed_date)
);
create index if not exists idx_feeding_notes_tenant on public.feeding_notes (tenant_id);
alter table public.feeding_notes enable row level security;
drop policy if exists feeding_notes_select on public.feeding_notes;
create policy feeding_notes_select on public.feeding_notes for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists feeding_notes_write on public.feeding_notes;
create policy feeding_notes_write on public.feeding_notes for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));
drop trigger if exists audit_feeding_notes on public.feeding_notes;
create trigger audit_feeding_notes after insert or update or delete on public.feeding_notes
  for each row execute function public.audit_trigger();

-- Tenant-reference guard now also covers feeding_notes.
create or replace function public.enforce_tenant_refs()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name in ('samples', 'production', 'feeding', 'digestate', 'recipes', 'feeding_notes') then
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
drop trigger if exists tenant_refs_feeding_notes on public.feeding_notes;
create trigger tenant_refs_feeding_notes before insert or update on public.feeding_notes
  for each row execute function public.enforce_tenant_refs();

-- ---- trend alarm on lab parameters -----------------------------------------
-- Latest value of a parameter at a plant vs the lowest (rising rule) or the
-- highest (falling rule) value measured in the preceding trend_days.
create or replace function public.eval_param_trend(p_tenant uuid, p_unit uuid, p_param uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_key    text;
  p        record;
  a        record;
  v_base   numeric;
  v_change numeric;
  v_uname  text;
  v_label  text;
begin
  if p_tenant is null or p_param is null then return; end if;
  v_key := 'trend:' || p_tenant || ':' || coalesce(p_unit::text, 'none') || ':' || p_param;

  select * into p from public.parameters where id = p_param;
  if not found or p.trend_delta is null or p.trend_delta = 0 or p.trend_days is null then
    perform public.clear_alert(v_key); return;
  end if;

  select an.value, coalesce(an.measured_at, an.created_at) as at, s.code as scode
    into a
    from public.analyses an
    join public.samples s on s.id = an.sample_id
   where an.tenant_id = p_tenant and an.parameter_id = p_param
     and s.unit_id is not distinct from p_unit
   order by coalesce(an.measured_at, an.created_at) desc, an.created_at desc
   limit 1;
  if not found or a.value is null then perform public.clear_alert(v_key); return; end if;

  select case when p.trend_delta > 0 then min(an.value) else max(an.value) end
    into v_base
    from public.analyses an
    join public.samples s on s.id = an.sample_id
   where an.tenant_id = p_tenant and an.parameter_id = p_param
     and s.unit_id is not distinct from p_unit
     and an.value is not null
     and coalesce(an.measured_at, an.created_at) >= a.at - make_interval(days => p.trend_days)
     and coalesce(an.measured_at, an.created_at) <  a.at;
  if v_base is null then perform public.clear_alert(v_key); return; end if;

  v_change := a.value - v_base;
  if (p.trend_delta > 0 and v_change >= p.trend_delta) or (p.trend_delta < 0 and v_change <= p.trend_delta) then
    select name into v_uname from public.units where id = p_unit;
    v_label := coalesce(p.label_el, p.code);
    perform public.raise_alert(p_tenant, p_unit, 'parameter', v_label || ' (τάση)', v_change,
      case when abs(v_change) >= 2 * abs(p.trend_delta) then 'critical' else 'warning' end,
      format('%s %s %s%s σε %s ημ. (%s → %s, όριο τάσης %s%s) · %s · δείγμα %s',
             v_label, case when v_change > 0 then 'ανοδική τάση' else 'καθοδική τάση' end,
             case when v_change > 0 then '+' else '' end, trim_scale(v_change)::text, p.trend_days,
             trim_scale(v_base)::text, trim_scale(a.value)::text,
             case when p.trend_delta > 0 then '+' else '' end, trim_scale(p.trend_delta)::text,
             coalesce(v_uname, '—'), coalesce(a.scode, '—')),
      v_key);
  else
    perform public.clear_alert(v_key);
  end if;
end;
$$;

-- Absolute-range alarm (unchanged rule) + trend alarm.
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
  perform public.eval_param_trend(p_tenant, p_unit, p_param);
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

-- ---- production rules: + planned stop, temperature drop, falling CH₄ -------
create or replace function public.eval_production_alerts(p_tenant uuid, p_unit uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  k_ch4   text;
  k_chp   text;
  k_temp  text;
  k_fall  text;
  r       record;
  v_uname text;
  v_prevt numeric;
  v_ch4   numeric[];
begin
  if p_tenant is null then return; end if;
  k_ch4  := 'prod-ch4:'      || p_tenant || ':' || coalesce(p_unit::text, 'none');
  k_chp  := 'prod-chp:'      || p_tenant || ':' || coalesce(p_unit::text, 'none');
  k_temp := 'prod-temp:'     || p_tenant || ':' || coalesce(p_unit::text, 'none');
  k_fall := 'prod-ch4-fall:' || p_tenant || ':' || coalesce(p_unit::text, 'none');

  select * into r from public.production
   where tenant_id = p_tenant and unit_id is not distinct from p_unit
   order by log_date desc, created_at desc
   limit 1;
  if not found then
    perform public.clear_alert(k_ch4); perform public.clear_alert(k_chp);
    perform public.clear_alert(k_temp); perform public.clear_alert(k_fall); return;
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

  -- a scheduled CHP stop (oil change, spark plugs …) is not a failure
  if r.chp_hours is not null and r.chp_hours < 20 and not r.planned_stop then
    perform public.raise_alert(p_tenant, p_unit, 'production', 'Ώρες ΣΗΘ', r.chp_hours,
      case when r.chp_hours < 16 then 'critical' else 'warning' end,
      format('Χαμηλή διαθεσιμότητα ΣΗΘ: %s ώρες (%s%%) · %s · %s', r.chp_hours, round(r.chp_hours / 24 * 100),
             coalesce(v_uname, '—'), to_char(r.log_date, 'DD/MM/YYYY')),
      k_chp);
  else
    perform public.clear_alert(k_chp);
  end if;

  -- heating failure shows as a fall of the daily reading (−1 °C/day rule)
  select digester_temp_c into v_prevt from public.production
   where tenant_id = p_tenant and unit_id is not distinct from p_unit and log_date = r.log_date - 1
   order by created_at desc limit 1;
  if r.digester_temp_c is not null and v_prevt is not null and r.digester_temp_c <= v_prevt - 1 then
    perform public.raise_alert(p_tenant, p_unit, 'production', 'Θερμοκρασία χωνευτή', r.digester_temp_c,
      case when r.digester_temp_c <= v_prevt - 2 then 'critical' else 'warning' end,
      format('Πτώση θερμοκρασίας χωνευτή %s °C σε μία ημέρα (%s → %s °C) — έλεγχος θέρμανσης · %s · %s',
             trim_scale(v_prevt - r.digester_temp_c)::text, trim_scale(v_prevt)::text, trim_scale(r.digester_temp_c)::text,
             coalesce(v_uname, '—'), to_char(r.log_date, 'DD/MM/YYYY')),
      k_temp);
  else
    perform public.clear_alert(k_temp);
  end if;

  -- CH₄ falling three days in a row (four consecutive daily logs, ≥ 1.5 points)
  select array_agg(ch4_pct order by log_date desc) into v_ch4
    from public.production
   where tenant_id = p_tenant and unit_id is not distinct from p_unit
     and log_date between r.log_date - 3 and r.log_date and ch4_pct is not null;
  if coalesce(array_length(v_ch4, 1), 0) = 4
     and v_ch4[1] < v_ch4[2] and v_ch4[2] < v_ch4[3] and v_ch4[3] < v_ch4[4]
     and v_ch4[4] - v_ch4[1] >= 1.5 then
    perform public.raise_alert(p_tenant, p_unit, 'production', 'CH₄ % (τάση)', v_ch4[1] - v_ch4[4], 'warning',
      format('Το μεθάνιο πέφτει 3 ημέρες συνεχόμενα: %s → %s%% (−%s μονάδες) — πιθανή αρχή οξίνισης · %s · %s',
             trim_scale(v_ch4[4])::text, trim_scale(v_ch4[1])::text, trim_scale(v_ch4[4] - v_ch4[1])::text,
             coalesce(v_uname, '—'), to_char(r.log_date, 'DD/MM/YYYY')),
      k_fall);
  else
    perform public.clear_alert(k_fall);
  end if;
end;
$$;

-- internal helper: not callable through the API
do $$
declare r text;
begin
  revoke all on function public.eval_param_trend(uuid,uuid,uuid) from public;
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on function public.eval_param_trend(uuid,uuid,uuid) from %I', r);
    end if;
  end loop;
end $$;
-- <<< END PHASE11 OBJECTS

-- ============================================================================
--  End of schema. Seed data lives in db/seed.sql.
-- ============================================================================
