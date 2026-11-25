-- ============================================================================
-- Migration 0011 — «Σήμερα» / trends (docs/OPERATOR_REVIEW.md Top-10 #4–#6, #10)
--
--   * parameters : trend_delta / trend_days — rate-of-change alarm per
--                  parameter (admin-configurable). The global FOS/TAC gets
--                  +0.05 within 14 days (db/seed.sql). A negative delta means
--                  "alarm on a fall" (e.g. pH −0.2 within 7 days).
--   * eval_param_trend() : latest value vs the extreme of the preceding
--                  trend_days → «τάση» alarm (critical at 2 × delta). Runs
--                  from eval_param_alert(), so every existing trigger path
--                  (analyses, samples, reevaluate_alerts) also evaluates trends.
--   * production : digester_temp_c (daily operator reading, 0–80 °C) and
--                  planned_stop (scheduled CHP maintenance → no availability
--                  alarm). New production rules: temperature drop ≥ 1 °C vs
--                  the previous day (critical ≥ 2 °C); CH₄ falling three days
--                  in a row by ≥ 1.5 points in total.
--   * feeding_notes : reason / note per digester and feeding day («γιατί
--                  έκοψα»), tenant-scoped, audited, tenant-reference guarded.
--
-- Idempotent: safe to run more than once. Mirrored verbatim into
-- db/schema.sql between the PHASE11 markers so a fresh install is identical.
-- ============================================================================

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
