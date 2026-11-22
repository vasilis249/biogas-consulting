-- ============================================================================
--  LabPortal — seed data
--  Global default parameters (tenant_id = NULL → available to every tenant).
--  Ideal ranges are placeholders — tune per crop/lab.
-- ============================================================================

insert into public.parameters (tenant_id, code, label_el, label_en, default_unit, ideal_min, ideal_max, sort_order) values
  (null, 'ph',   'pH',             'pH',            '',       5.5,  6.5, 10),
  (null, 'ec',   'Αγωγιμότητα',    'EC',            'mS/cm',  1.5,  2.5, 20),
  (null, 'n',    'Άζωτο (N)',      'Nitrogen (N)',  'mg/l',   100,  200, 30),
  (null, 'p',    'Φώσφορος (P)',   'Phosphorus (P)','mg/l',   30,   50,  40),
  (null, 'k',    'Κάλιο (K)',      'Potassium (K)', 'mg/l',   150,  300, 50),
  (null, 'ca',   'Ασβέστιο (Ca)',  'Calcium (Ca)',  'mg/l',   100,  200, 60),
  (null, 'mg',   'Μαγνήσιο (Mg)',  'Magnesium (Mg)','mg/l',   30,   60,  70),
  (null, 'temp', 'Θερμοκρασία',    'Temperature',   '°C',     18,   26,  80),
  (null, 'moist','Υγρασία',        'Moisture',      '%',      60,   80,  90)
on conflict (tenant_id, code) do nothing;

-- ---------------------------------------------------------------------------
-- Optional demo tenant (uncomment to create a sandbox client).
-- After creating an auth user in Supabase, attach them with:
--   update public.profiles
--      set tenant_id = (select id from public.tenants where slug = 'demo'),
--          role = 'admin'
--    where email = 'you@example.com';
-- ---------------------------------------------------------------------------
-- insert into public.tenants (name, slug) values ('Demo Client', 'demo')
--   on conflict (slug) do nothing;
