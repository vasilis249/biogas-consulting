-- Order-independent fingerprint of the public schema: columns, constraints,
-- indexes, RLS, policies, triggers, function bodies, views, enums and function
-- grants. Used to prove "fresh install" == "upgraded via migrations".
select line from (
  select 'col '  || table_name || '.' || column_name || ' ' || data_type
         || ' null=' || is_nullable || ' def=' || coalesce(column_default, '') as line
    from information_schema.columns where table_schema = 'public'
  union all
  select 'con '  || conrelid::regclass || ' ' || conname || ' ' || pg_get_constraintdef(oid)
    from pg_constraint where connamespace = 'public'::regnamespace
  union all
  select 'idx '  || pg_get_indexdef(i.indexrelid)
    from pg_index i join pg_class c on c.oid = i.indrelid
   where c.relnamespace = 'public'::regnamespace
  union all
  select 'rls '  || relname || ' ' || relrowsecurity
    from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r'
  union all
  select 'pol '  || tablename || ' ' || policyname || ' ' || cmd || ' ' || coalesce(qual, '') || ' | ' || coalesce(with_check, '')
    from pg_policies where schemaname = 'public'
  union all
  select 'trg '  || pg_get_triggerdef(t.oid)
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where not t.tgisinternal and c.relnamespace = 'public'::regnamespace
  union all
  select 'fn '   || p.oid::regprocedure || ' ' || md5(pg_get_functiondef(p.oid))
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname not like '\_t\_%'
  union all
  select 'view ' || viewname || ' ' || md5(definition) from pg_views where schemaname = 'public'
  union all
  select 'enum ' || t.typname || ' ' || string_agg(e.enumlabel, ',' order by e.enumlabel)
    from pg_type t join pg_enum e on e.enumtypid = t.oid group by t.typname
  union all
  select 'fgrant ' || p.oid::regprocedure || ' ' || r.rolname || ' ' || has_function_privilege(r.oid, p.oid, 'EXECUTE')
    from pg_proc p cross join pg_roles r
   where p.pronamespace = 'public'::regnamespace and p.proname not like '\_t\_%'
     and r.rolname in ('anon', 'authenticated')
) f
order by line;
