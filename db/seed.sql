-- ============================================================================
--  BioGas edition — seed data
--  Global default parameters (tenant_id = NULL → available to every tenant).
--  Ideal ranges act as digester-stability / gas-quality bands; tune per plant.
-- ============================================================================

insert into public.parameters (tenant_id, code, label_el, label_en, default_unit, ideal_min, ideal_max, sort_order) values
  -- digester stability
  (null, 'ph_dig',  'pH χωνευτή',          'Digester pH',        '',      7.4,  8.2, 10),
  (null, 'fos_tac', 'FOS/TAC',             'FOS/TAC',            '',      0.2,  0.4, 20),
  (null, 'temp_dig','Θερμοκρασία χωνευτή', 'Digester temp',      '°C',    38,   42,  30),
  (null, 'ts',      'Ξηρά ουσία (TS)',     'Total solids (TS)',  '%',     7,    12,  40),
  (null, 'vs',      'Οργανική ουσία (VS)', 'Volatile solids',    '% TS',  70,   85,  50),
  (null, 'vfa',     'Πτητικά οξέα (VFA)',  'VFA',                'mg/l',  0,    2000,60),
  (null, 'nh4',     'Αμμωνιακό N (NH₄-N)', 'Ammonium N',         'mg/l',  500,  3000,70),
  -- biogas quality
  (null, 'ch4',     'Μεθάνιο (CH₄)',       'Methane (CH₄)',      '%',     50,   60,  80),
  (null, 'co2',     'Διοξείδιο (CO₂)',     'Carbon dioxide',     '%',     38,   48,  90),
  (null, 'h2s',     'Υδρόθειο (H₂S)',      'Hydrogen sulfide',   'ppm',   0,    300, 100),
  (null, 'o2',      'Οξυγόνο (O₂)',        'Oxygen (O₂)',        '%',     0,    1,   110)
on conflict (tenant_id, code) do nothing;

-- Optional demo tenant (see earlier comment / docs for the attach flow).
