-- ============================================================================
--  LabPortal — Migration 0004: Phase 4 storage
--  Creates the private "attachments" bucket and tenant-scoped Storage RLS,
--  plus audit logging on the files table.
--
--  NOTE: requires Supabase's `storage` schema → run this ON SUPABASE, not on a
--  bare PostgreSQL. (The rest of the schema stays plain-Postgres compatible.)
--
--  File path convention enforced by these policies:
--      <tenant_id>/<sample_id>/<timestamp>_<filename>
--  i.e. the FIRST path segment must equal the caller's tenant_id.
-- ============================================================================

-- Private bucket for sample attachments / photos.
insert into storage.buckets (id, name, public)
values ('attachments', 'attachments', false)
on conflict (id) do nothing;

-- --- Storage RLS: isolate by the first folder segment = tenant_id -----------
drop policy if exists "attachments_read"   on storage.objects;
drop policy if exists "attachments_insert" on storage.objects;
drop policy if exists "attachments_update" on storage.objects;
drop policy if exists "attachments_delete" on storage.objects;

create policy "attachments_read" on storage.objects for select to authenticated
  using (
    bucket_id = 'attachments'
    and (public.is_platform_admin()
         or (storage.foldername(name))[1] = public.auth_tenant_id()::text)
  );

create policy "attachments_insert" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'attachments'
    and (public.is_platform_admin()
         or ((storage.foldername(name))[1] = public.auth_tenant_id()::text and public.can_write()))
  );

create policy "attachments_update" on storage.objects for update to authenticated
  using (
    bucket_id = 'attachments'
    and (public.is_platform_admin()
         or ((storage.foldername(name))[1] = public.auth_tenant_id()::text and public.can_write()))
  );

create policy "attachments_delete" on storage.objects for delete to authenticated
  using (
    bucket_id = 'attachments'
    and (public.is_platform_admin()
         or ((storage.foldername(name))[1] = public.auth_tenant_id()::text and public.can_write()))
  );

-- --- Audit the files table too (generic trigger from migration 0003) --------
drop trigger if exists audit_files on public.files;
create trigger audit_files after insert or update or delete on public.files
  for each row execute function public.audit_trigger();

-- ============================================================================
--  End migration 0004.
-- ============================================================================
