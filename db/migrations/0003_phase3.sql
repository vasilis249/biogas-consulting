-- ============================================================================
--  LabPortal — Migration 0003: Phase 3
--  Adds: invitations (invite → auto-assign on signup), audit triggers.
--  Safe to run on an existing v1/v2 database. For a fresh install this is
--  already folded into db/schema.sql.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Invitations: a tenant admin / platform admin pre-authorises an email.
--    When that person signs up, the signup trigger auto-assigns tenant+role.
-- ---------------------------------------------------------------------------
create table if not exists public.invitations (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  email       text not null,
  role        public.user_role not null default 'operator',
  invited_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  accepted_at timestamptz
);
create index if not exists idx_invitations_email  on public.invitations (lower(email));
create index if not exists idx_invitations_tenant on public.invitations (tenant_id);

grant select, insert, update, delete on public.invitations to authenticated;

alter table public.invitations enable row level security;

-- Platform admin, or the tenant's own admin, may manage its invitations.
drop policy if exists invitations_rw on public.invitations;
create policy invitations_rw on public.invitations for all
  using (public.is_platform_admin()
         or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'))
  with check (public.is_platform_admin()
         or (tenant_id = public.auth_tenant_id() and public.auth_role() = 'admin'));

-- ---------------------------------------------------------------------------
-- 2. Signup trigger now consumes a matching pending invitation.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare inv public.invitations;
begin
  select * into inv
    from public.invitations
   where lower(email) = lower(new.email) and accepted_at is null
   order by created_at desc
   limit 1;

  insert into public.profiles (id, email, full_name, tenant_id, role)
  values (
    new.id, new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    inv.tenant_id,
    coalesce(inv.role, 'viewer'::public.user_role)
  )
  on conflict (id) do nothing;

  if inv.id is not null then
    update public.invitations set accepted_at = now() where id = inv.id;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Audit trail: a generic trigger logs insert/update/delete on key tables.
--    SECURITY DEFINER so logging always succeeds regardless of the caller.
-- ---------------------------------------------------------------------------
create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_id uuid;
begin
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
  foreach t in array array['units','parameters','samples','analyses','invoices','profiles']
  loop
    execute format('drop trigger if exists audit_%1$s on public.%1$s', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$s
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- ============================================================================
--  End migration 0003.
-- ============================================================================
