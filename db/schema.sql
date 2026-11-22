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
  unique (tenant_id, code)
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
--  End of schema. Seed data lives in db/seed.sql.
-- ============================================================================
