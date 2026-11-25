-- ============================================================================
-- Migration 0009 — RED III sustainability (GHG emission savings)
--
-- Adds the regulatory configuration needed to assess a plant against the
-- Article 29(10) greenhouse-gas-savings threshold and to run the Annex VI
-- default-value methodology:
--   * units      : commissioning date, total rated thermal input, CHP case,
--                  digestate storage, product (electricity/biomethane), off-gas
--   * feedstocks : RED III default-value class (manure / maize / biowaste)
--
-- No new tables, no RLS changes — the columns inherit each table's policies.
-- Idempotent: safe to run more than once. Mirrored verbatim into
-- db/schema.sql between the PHASE9 markers so a fresh install is identical.
-- ============================================================================

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
