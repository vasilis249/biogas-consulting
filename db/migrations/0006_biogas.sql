-- ============================================================================
--  LabPortal → BioGas edition — Migration 0006
--  Adapts the platform to biogas plant operation & consulting:
--   - biogas-specific sample kinds (digester / substrate / biogas / digestate …)
--   - plant metadata on units (electrical capacity, digester volume)
--   - a daily production log (feedstock, biogas, CH4, CHP energy & hours)
--   - a global biogas parameter set (stability + gas-quality) with ideal ranges
--  Safe to run on an existing database.
-- ============================================================================

-- --- 1. Extend sample kinds for biogas sampling -----------------------------
alter type public.sample_kind add value if not exists 'digester';
alter type public.sample_kind add value if not exists 'substrate_in';
alter type public.sample_kind add value if not exists 'digestate';
alter type public.sample_kind add value if not exists 'biogas';
alter type public.sample_kind add value if not exists 'influent';
alter type public.sample_kind add value if not exists 'effluent';

-- --- 2. Plant metadata on units ---------------------------------------------
alter table public.units add column if not exists capacity_kw  numeric;   -- CHP electrical capacity (kWel)
alter table public.units add column if not exists digester_m3  numeric;   -- active digester volume (m³)

-- --- 3. Daily production / operation log -------------------------------------
create table if not exists public.production (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  unit_id      uuid references public.units (id) on delete set null,
  log_date     date not null,
  feedstock_t  numeric,     -- substrate fed (tonnes)
  biogas_m3    numeric,     -- biogas produced (m³)
  ch4_pct      numeric,     -- methane content (%)
  kwh_el       numeric,     -- electricity produced (kWh)
  kwh_th       numeric,     -- useful heat produced (kWh)
  chp_hours    numeric,     -- CHP operating hours
  flare_hours  numeric,     -- flare operating hours
  notes        text,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists idx_production_tenant on public.production (tenant_id);
create index if not exists idx_production_unit   on public.production (unit_id);
create index if not exists idx_production_date   on public.production (log_date);

grant select, insert, update, delete on public.production to authenticated;

alter table public.production enable row level security;
drop policy if exists production_select on public.production;
create policy production_select on public.production for select
  using (public.is_platform_admin() or tenant_id = public.auth_tenant_id());
drop policy if exists production_write on public.production;
create policy production_write on public.production for all
  using (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()))
  with check (public.is_platform_admin() or (tenant_id = public.auth_tenant_id() and public.can_write()));

drop trigger if exists audit_production on public.production;
create trigger audit_production after insert or update or delete on public.production
  for each row execute function public.audit_trigger();

-- --- 4. Global biogas parameter set (ideal ranges = stability bands) ---------
insert into public.parameters (tenant_id, code, label_el, label_en, default_unit, ideal_min, ideal_max, sort_order) values
  (null, 'ph_dig',  'pH χωνευτή',          'Digester pH',        '',      7.4,  8.2, 10),
  (null, 'fos_tac', 'FOS/TAC',             'FOS/TAC',            '',      0.2,  0.4, 20),
  (null, 'temp_dig','Θερμοκρασία χωνευτή', 'Digester temp',      '°C',    38,   42,  30),
  (null, 'ts',      'Ξηρά ουσία (TS)',     'Total solids (TS)',  '%',     7,    12,  40),
  (null, 'vs',      'Οργανική ουσία (VS)', 'Volatile solids',    '% TS',  70,   85,  50),
  (null, 'vfa',     'Πτητικά οξέα (VFA)',  'VFA',                'mg/l',  0,    2000,60),
  (null, 'nh4',     'Αμμωνιακό N (NH₄-N)', 'Ammonium N',         'mg/l',  500,  3000,70),
  (null, 'ch4',     'Μεθάνιο (CH₄)',       'Methane (CH₄)',      '%',     50,   60,  80),
  (null, 'co2',     'Διοξείδιο (CO₂)',     'Carbon dioxide',     '%',     38,   48,  90),
  (null, 'h2s',     'Υδρόθειο (H₂S)',      'Hydrogen sulfide',   'ppm',   0,    300, 100),
  (null, 'o2',      'Οξυγόνο (O₂)',        'Oxygen (O₂)',        '%',     0,    1,   110)
on conflict (tenant_id, code) do nothing;

-- ============================================================================
--  End migration 0006.
-- ============================================================================
