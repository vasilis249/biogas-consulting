# LabPortal — Σχέδιο & Αρχιτεκτονική

Πλατφόρμα **εργαστηριακών αναλύσεων για αγροδιατροφή** (δείγματα, μετρήσεις
pH/EC/NPK, μονάδες, reports), για να την προσφέρεις στους **δικούς σου πελάτες**.

> Πρωτότυπο προϊόν, γραμμένο από το μηδέν με βάση γενικές έννοιες του χώρου.
> Δεν αντιγράφει κώδικα, UI ή branding τρίτων.

---

## 1. Tech stack
- **Frontend:** ένα `index.html` + vanilla JS (ESM) — ίδιο ύφος με το AGRINNERA stock app σου.
- **Backend / DB:** **Supabase** (PostgreSQL, Auth, Storage, Row-Level Security).
- **Χωρίς δικό σου server:** όλη η λογική πρόσβασης ζει στη βάση (RLS), το frontend
  μιλάει απευθείας με το Supabase μέσω του anon key.
- **Εξαγωγές:** SheetJS (xlsx) για Excel, εκτύπωση/PDF από τον browser.

## 2. Μοντέλο πολλαπλών πελατών (multi-tenant)
**Ένα app, πολλοί πελάτες.** Κάθε πελάτης = ένα `tenant`. Κάθε εγγραφή δεδομένων
κρατάει `tenant_id` και απομονώνεται με **RLS**:

- **Platform admin (εσύ):** `is_platform_admin = true`, βλέπει/διαχειρίζεται τα πάντα.
- **Χρήστης πελάτη:** βλέπει **μόνο** τα δεδομένα του δικού του tenant.
- Η απομόνωση επιβάλλεται στη **βάση**, όχι στο UI — δεν παρακάμπτεται από τον browser.

Ρόλοι ανά tenant:

| Ρόλος | Διαβάζει | Γράφει | Οικονομικά | Διαχείριση χρηστών |
|---|---|---|---|---|
| `admin` | ✅ | ✅ | ✅ | ✅ (του tenant) |
| `operator` | ✅ | ✅ ημερήσια δεδομένα* | ❌ | ❌ |
| `viewer` | ✅ | ❌ | ❌ | ❌ |

\* Από τη migration 0010 ο `operator` γράφει δείγματα/αναλύσεις, παραγωγή, τροφοδοσία,
χώνευμα, υποστρώματα & συνταγές, αλλά **όχι** μονάδες/χωνευτές (`units`) και όρια
συναγερμών (`parameters`): αυτά είναι μόνο για `admin` (RLS μέσω `is_tenant_admin()`).

## 3. Data model
Πλήρες schema: [`db/schema.sql`](../db/schema.sql) · seed: [`db/seed.sql`](../db/seed.sql)

- **`tenants`** — οι πελάτες σου (name, slug, status, settings).
- **`profiles`** — 1 ανά Supabase auth user· `tenant_id`, `role`, `is_platform_admin`.
- **`units`** — μονάδες/εγκαταστάσεις ενός πελάτη (θερμοκήπια, αγροτεμάχια…).
- **`parameters`** — κατάλογος μετρούμενων μεγεθών με **ιδανικό εύρος**
  (pH, EC, N, P, K, Ca, Mg, θερμοκρασία, υγρασία). Global defaults + ανά tenant.
- **`samples`** — δείγματα (kind: leaf/soil/water/reservoir/…, status, taken_at).
- **`analyses`** — μετρήσεις ανά δείγμα (EAV: `parameter_id`, `value`, `unit`) → ευέλικτο.
- **`files`** — μεταδεδομένα συνημμένων· τα bytes σε Supabase Storage bucket.
- **`invoices`** — ελαφρύ module Οικονομικών (period, amount, status).
- **`audit_log`** — ιστορικό ενεργειών για admin visibility & ασφάλεια.

### Σχέση οντοτήτων
```
tenant ──< units ──< samples ──< analyses >── parameters
   │                    │
   │                    └──< files
   ├──< profiles (users)
   ├──< invoices
   └──< audit_log
```

## 4. Ασφάλεια (built-in)
- **RLS σε κάθε πίνακα** — ο διαχωρισμός πελατών δεν εξαρτάται από το frontend.
- Helper functions `is_platform_admin()`, `auth_tenant_id()`, `auth_role()`,
  `can_write()` (SECURITY DEFINER, ώστε να μην έχουμε recursion στα RLS policies).
- Auto-provision profile με trigger στο signup (`handle_new_user`).
- Write μόνο για `admin`/`operator`· `viewer` = read-only. Ρύθμιση εγκατάστασης
  (`units`) και όρια συναγερμών (`parameters`) μόνο `admin` (`is_tenant_admin()`, 0010).
- Οικονομικά: write μόνο `admin`.
- Προτεινόμενα αργότερα: 2FA/OTP στο login (Supabase MFA), CSRF δεν χρειάζεται
  (token-based auth, όχι cookies), rate limiting στο edge.

## 5. Οθόνες (MVP)
1. **Login** (Supabase Auth, email+password· MFA αργότερα).
2. **Dashboard** — σύνοψη ανά μονάδα, τελευταία δείγματα, τιμές εκτός ιδανικού εύρους (χρωματικά).
3. **Δείγματα** — λίστα/φίλτρα, δημιουργία, καρτέλα δείγματος με τις αναλύσεις του.
4. **Μαζική καταχώρηση** — γρήγορη εισαγωγή πολλών μετρήσεων (πίνακας).
5. **Μονάδες & Παράμετροι** — διαχείριση (admin).
6. **Reports** — μηνιαία σύνοψη + export Excel/PDF.
7. **Admin** — χρήστες του tenant, Οικονομικά, audit log.
8. **Platform admin** (μόνο εσύ) — δημιουργία/διαχείριση tenants.

## 6. Roadmap
- **Φάση 1 (MVP):** schema + RLS ✅ · Auth + Dashboard + Δείγματα/Αναλύσεις + μαζική καταχώρηση ✅
- **Φάση 2:** Reports + Excel/CSV export ✅ · διαχείριση παραμέτρων & μονάδων ✅ (αρχεία/Storage: εκκρεμεί)
- **Φάση 3:** διαχείριση χρηστών & προσκλήσεις ✅ · MFA/TOTP ✅ · audit log UI ✅
- **Φάση 4:** αρχεία/φωτό ανά δείγμα (Supabase Storage) ✅ · Οικονομικά UI (τιμολόγια) ✅ · branding ανά πελάτη (χρώμα/όνομα) ✅ · **EL/EN toggle: εκκρεμεί** (ξεχωριστό i18n pass)
- **Φάση 5:** forgot-password + email-OTP login ✅ · presence/«online» χρήστες (`last_seen`) ✅ · Backup/Export (JSON) ✅ · Μηνιαία αναφορά (ΥΠΕΝ-style, Excel+εκτύπωση) ✅
- **Φάση 6 (BioGas edition):** προσαρμογή σε **biogas plant operation & consulting** ✅
  - Biogas παράμετροι σταθερότητας & ποιότητας αερίου (pH χωνευτή, FOS/TAC, VFA, TS/VS, NH₄-N, CH₄, CO₂, H₂S, O₂) με ιδανικά εύρη → το dashboard σημαίνει ασταθείς χωνευτές.
  - Μεταδεδομένα μονάδας/χωνευτή (ισχύς ΣΗΘ kWel, όγκος m³) + biogas τύποι δειγμάτων (χωνευτής/υπόστρωμα/βιοαέριο/χώνευμα/εισροή/εκροή).
  - Νέο module **Παραγωγή**: ημερήσιο log (τροφοδοσία t, βιοαέριο m³, CH₄ %, kWh el/th, ώρες ΣΗΘ) + KPIs (MWh, Μ.Ο. CH₄, διαθεσιμότητα ΣΗΘ, ειδική απόδοση m³/t) + Excel.
  - `db/migrations/0006_biogas.sql` (+ πίνακας `production`, RLS, audit — validated σε Postgres 16).
- **Φάση 7 (BioGas operations):** ✅
  - **Μητρώο υποστρωμάτων** (TS/VS/BMP/τιμή/C:N) με αυτόματη απόδοση m³ CH₄/t.
  - **Τροφοδοσία**: σχεδιασμός σιτηρεσίου με live **OLR/HRT**, αναμενόμενη παραγωγή & κόστος, συνταγές, ημερολόγιο με πραγματική vs αναμενόμενη απόδοση (view `feeding_daily`, RPC `replace_feeding`).
  - **Χώνευμα**: παραγωγή/διάθεση/θρεπτικά + έλεγχος **Οδηγίας Νιτρορύπανσης** (170 kg N/ha/έτος ανά παραλήπτη).
  - **Ειδοποιήσεις**: αυτόματοι συναγερμοί στη βάση (triggers) για σταθερότητα χωνευτή, αέριο, ΣΗΘ, OLR/HRT, άζωτο — state-based (ενεργός→σε γνώση→επιλύθηκε, κλιμάκωση), με **email digests** (Edge Function `send-alerts` + pg_cron). Βλ. `docs/ALERTS_EMAIL.md`.
  - DB: `migrations/0007` (+`feedstocks`,`recipes`,`feeding`,`digestate`,`alerts`,`alert_recipients`, alarm engine, tenant-ref guard) & `0008` (cron). Tests: `tests/sql/run_local.sh`, `tests/digest.test.mjs`, `tests/e2e/demo_smoke.mjs`.
- **Φάση 8 — Ισοζύγιο μάζας & ενέργειας:** ✅ (client-side, από τα υπάρχοντα δεδομένα — χωρίς αλλαγή schema)
  - Μάζα: υποστρώματα (νωπό/TS/VS) → βιοαέριο (m³ × πυκνότητα από CH₄%: ρ = x·0,7175 + (1−x)·1,977 kg/Nm³) + χώνευμα → **κλείσιμο %**, διάγραμμα ροής.
  - Απομάκρυνση οργανικής ουσίας με **Van Kleeck**: VSR = (Fi − Fo)/(Fi − Fi·Fo), Fi = VS/TS τροφοδοσίας, Fo = VS/TS χωνευτή (τελευταία ανάλυση, σταθμισμένη ανά μονάδα).
  - Ενέργεια: CH₄ × 9,97 kWh/m³ → η_el, η_th, απώλειες· ειδική απόδοση vs BMP· διαθεσιμότητα ΣΗΘ· αυτόματες παρατηρήσεις ποιότητας δεδομένων· Excel/εκτύπωση.
- **Φάση 9 — Αειφορία RED III:** ✅ μείωση GHG με προεπιλεγμένες τιμές Παραρτήματος VI (co-digestion Wₙ/Sₙ/Pₙ), όριο άρθρου 29(10) ανά ημ/νία έναρξης & ισχύ, σενάρια (αποθήκευση χωνεύματος × Case), αποφυγή tCO₂eq, Excel. `lib/red3.js` + `tests/red3.test.mjs` (αναπαράγει τους επίσημους πίνακες), `migrations/0009`. Βλ. `docs/RED3.md`.
- **Φάση 10 — Διορθώσεις operator review (P1):** ✅ `migrations/0010`: μία εγγραφή παραγωγής ανά χωνευτή/ημέρα (unique, με «Αντικατάσταση;» στη φόρμα· τα υπάρχοντα διπλότυπα συμπτύσσονται και σώζονται αυτούσια στο `audit_log`), φυσικά όρια (CH₄ 0–100 %, ώρες ΣΗΘ/πυρσού 0–24, όχι αρνητικά — CHECK, NOT VALID αν υπάρχουν παλιά «βρώμικα» δεδομένα), μονάδες & όρια συναγερμών μόνο για admin. UI: πεδίο ώρες πυρσού, προεπιλογή χθεσινή ημέρα, έλεγχος kWh ≤ ισχύς ΣΗΘ × 24 h, σχεδιασμός σιτηρεσίου που φορτώνει τον σωστό χωνευτή, προειδοποίηση πριν από υπέρβαση 170 kg N/ha, τοπικές ημερομηνίες αντί για UTC, toast χωρίς pointer-events. Tests: `tests/sql/test_phase10.sql`, upgrade path στο `run_local.sh`, ενότητα «Operator review — P1 fixes» στο E2E. Βλ. `docs/OPERATOR_REVIEW.md` §0.
- **Φάση 11 — «Σήμερα», τάσεις & ημερήσιες ενδείξεις:** ✅ `migrations/0011`: συναγερμός **τάσης** ανά παράμετρο (`parameters.trend_delta/trend_days`, ρυθμίζεται από admin· FOS/TAC +0,05 σε 14 ημ. στο seed· κρίσιμο στη διπλάσια μεταβολή· αρνητική τιμή = πτώση), ημερήσια θερμοκρασία χωνευτή με κανόνα −1 °C/ημέρα (κρίσιμο −2 °C), CH₄ παραγωγής σε πτώση 3 ημέρες (≥ 1,5 μονάδες), «προγραμματισμένη στάση ΣΗΘ» χωρίς συναγερμό διαθεσιμότητας, `feeding_notes` (αιτία αλλαγής σιτηρεσίου). UI: αρχική **«Σήμερα»** με κάρτα ανά χωνευτή (φανάρι, χθεσινές MWh/ώρες ΣΗΘ/CH₄/θερμοκρασία, OLR/HRT, τελευταίες αναλύσεις με βελάκια και sparklines 8 εβδομάδων, συναγερμοί ομαδοποιημένοι σε διάγνωση π.χ. «Πιθανή οξίνιση»), σχεδιασμός που δείχνει FOS/TAC/VFA/pH και επικροτεί τη μείωση σε ασταθή χωνευτή (προτείνει πρώτα τα εύπεπτα). Tests: `tests/sql/test_phase11.sql`, E2E «Wave A».
- **Μελλοντικά:** πιστοποίηση με actual values (ISCC), guarantees of origin (ΔΑΠΕΕΠ), ισοζύγιο αζώτου εισόδου (N υποστρωμάτων), email προσκλήσεων χρηστών, πλήρες EL/EN.

### Migrations (συνέχεια)
- `0005_phase5.sql`: `profiles.last_seen` + audit guard (τα heartbeats δεν καταγράφονται).

### Storage (Φάση 4)
Αρχεία ανά δείγμα σε private bucket `attachments`. Path: `<tenant_id>/<sample_id>/<ts>_<file>`.
Η απομόνωση επιβάλλεται με **Storage RLS** (πρώτο path segment = tenant_id). Άνοιγμα μέσω
signed URL (120s). Τα policies είναι στο `db/migrations/0004_phase4_storage.sql` (**Supabase-only**,
χρειάζεται το `storage` schema — δεν τρέχει σε σκέτη Postgres).

### Invitation flow (Φάση 3)
Δεν στέλνεται email αυτόματα (θα χρειαζόταν service_role → Edge Function). Αντ' αυτού:
admin → «Πρόσκληση» (email + ρόλος) αποθηκεύεται στον πίνακα `invitations` → ο χρήστης
κάνει **self-signup** με το ίδιο email → το trigger `handle_new_user` τον αντιστοιχίζει
αυτόματα στον πελάτη με τον ρόλο. (Μελλοντικά: email πρόσκλησης μέσω Edge Function.)

### Migrations
- Fresh install: `db/schema.sql` περιέχει τα Φάσεων 1–4 εκτός Storage· μετά τρέξε
  `db/migrations/0004_phase4_storage.sql` (bucket + storage policies, Supabase-only).
- Υπάρχουσα βάση: τρέξε με τη σειρά `0003_phase3.sql` → `0004_phase4_storage.sql`.

## 7. Επόμενα βήματα (setup)
1. Φτιάξε project στο Supabase → πάρε `Project URL` + `anon key`.
2. Τρέξε `db/schema.sql` και μετά `db/seed.sql` στον SQL editor.
3. Έφτιαξε Storage bucket `attachments` (private).
4. Κάνε signup τον εαυτό σου· set `is_platform_admin = true` στο profile σου.
5. Άνοιξε το `index.html`, σύνδεσε URL+anon key, κάνε login.
6. (2FA) Από «Ασφάλεια» → «Ενεργοποίηση 2FA» με Google Authenticator/Authy.
