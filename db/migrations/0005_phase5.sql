-- ============================================================================
--  LabPortal — Migration 0005: Phase 5
--  Adds profiles.last_seen (presence / "recently active") and makes the audit
--  trigger ignore last_seen-only profile updates (so heartbeats don't spam it).
--  Safe to run on an existing database.
-- ============================================================================

alter table public.profiles add column if not exists last_seen timestamptz;

-- Replace the generic audit trigger with a version that skips a profiles
-- UPDATE whose only change is last_seen.
create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_id uuid;
begin
  if (tg_op = 'UPDATE' and tg_table_name = 'profiles') then
    if (to_jsonb(new) - 'last_seen') = (to_jsonb(old) - 'last_seen') then
      return new;   -- heartbeat only → do not log
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

-- ============================================================================
--  End migration 0005.
-- ============================================================================
