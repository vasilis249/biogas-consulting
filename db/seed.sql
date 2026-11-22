-- ============================================================================
--  BioGas edition — seed data (idempotent; safe to re-run)
--  Global defaults (tenant_id = NULL → available to every tenant).
--  Values are indicative literature figures: tune per plant with lab analyses.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Parameters. Ideal ranges = digester-stability / gas-quality bands; the alarm
-- engine raises "warning" outside the band, "critical" beyond it by > 20 %.
-- ---------------------------------------------------------------------------
insert into public.parameters (tenant_id, code, label_el, label_en, default_unit, ideal_min, ideal_max, sort_order) values
  -- digester stability
  (null, 'ph_dig',   'pH χωνευτή',                  'Digester pH',       '',      7.4,  8.2,  10),
  (null, 'fos_tac',  'FOS/TAC',                     'FOS/TAC',           '',      0.2,  0.4,  20),
  (null, 'temp_dig', 'Θερμοκρασία χωνευτή',         'Digester temp',     '°C',    38,   42,   30),
  (null, 'ts',       'Ξηρά ουσία (TS)',             'Total solids (TS)', '%',     7,    12,   40),
  (null, 'vs',       'Οργανική ουσία (VS)',         'Volatile solids',   '% TS',  70,   85,   50),
  (null, 'vfa',      'Πτητικά οξέα (VFA)',          'VFA',               'mg/l',  0,    2000, 60),
  (null, 'nh4',      'Αμμωνιακό N (NH₄-N)',         'Ammonium N',        'mg/l',  500,  3000, 70),
  -- biogas quality
  (null, 'ch4',      'Μεθάνιο (CH₄)',               'Methane (CH₄)',     '%',     50,   60,   80),
  (null, 'co2',      'Διοξείδιο (CO₂)',             'Carbon dioxide',    '%',     38,   48,   90),
  (null, 'h2s',      'Υδρόθειο (H₂S)',              'Hydrogen sulfide',  'ppm',   0,    300,  100),
  (null, 'o2',       'Οξυγόνο (O₂)',                'Oxygen (O₂)',       '%',     0,    1,    110),
  -- digestate nutrients (informational: no band → no alarms)
  (null, 'dig_n',    'Ολικό άζωτο χωνεύματος (N)',  'Digestate total N', 'kg/t',  null, null, 120),
  (null, 'dig_p2o5', 'Φώσφορος χωνεύματος (P₂O₅)',  'Digestate P₂O₅',    'kg/t',  null, null, 130),
  (null, 'dig_k2o',  'Κάλιο χωνεύματος (K₂O)',      'Digestate K₂O',     'kg/t',  null, null, 140)
on conflict (tenant_id, code) do nothing;

-- ---------------------------------------------------------------------------
-- Feedstock registry: TS % (fresh), VS % (of TS), BMP m³ CH₄ / t VS,
-- price €/t (negative = gate fee / income), C:N.
-- ---------------------------------------------------------------------------
insert into public.feedstocks (tenant_id, name, category, ts_pct, vs_pct, bmp, price_eur_t, cn_ratio, notes) values
  (null, 'Υγρή κοπριά βοοειδών',              'manure',           8, 80, 210,   0,  10, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Στερεή κοπριά βοοειδών',             'manure',          22, 80, 230,   0,  18, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Υγρή κοπριά χοίρων',                 'manure',           5, 75, 300,   0,   8, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Κοπριά πουλερικών',                  'manure',          40, 75, 280,   5,   8, 'Ενδεικτικές τιμές βιβλιογραφίας — υψηλό N, προσοχή στην αμμωνία'),
  (null, 'Ενσίρωμα αραβοσίτου',                'energy_crop',     33, 95, 340,  40,  40, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Ενσίρωμα χόρτου / τριφυλλιού',       'energy_crop',     30, 90, 300,  30,  20, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Τυρόγαλα (ορός γάλακτος)',           'agro_industrial',  6, 85, 450,   0,  15, 'Ταχεία οξίνιση — δοσολογία σταδιακά'),
  (null, 'Κατσίγαρος (απόνερα ελαιοτριβείου)', 'agro_industrial', 10, 80, 400,   0,  30, 'Πολυφαινόλες — περιορισμένο ποσοστό στο μίγμα'),
  (null, 'Ελαιοπυρήνας (υγρός, 2 φάσεων)',     'agro_industrial', 30, 90, 330,   0,  45, 'Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP'),
  (null, 'Φλούδες εσπεριδοειδών',              'agro_industrial', 20, 95, 380,   0,  30, 'Λιμονένιο — περιορισμένο ποσοστό στο μίγμα'),
  (null, 'Περιεχόμενο στομάχων (σφαγεία)',     'agro_industrial', 15, 85, 350, -10,  20, 'Αρνητική τιμή = έσοδο (gate fee)'),
  (null, 'Απόβλητα τροφίμων / εστίασης',       'food_waste',      25, 90, 450, -20,  18, 'Αρνητική τιμή = έσοδο (gate fee) — απαιτείται υγιεινοποίηση'),
  (null, 'Ακατέργαστη γλυκερίνη',              'other',           80, 95, 450,  50, 150, 'Πολύ υψηλή απόδοση — μικρό ποσοστό (≤5%)')
on conflict (tenant_id, name) do nothing;
