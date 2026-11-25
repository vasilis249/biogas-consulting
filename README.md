# LabPortal

Πολυ-πελατειακή (multi-tenant) πλατφόρμα εργαστηριακών αναλύσεων για αγροδιατροφή:
δείγματα, μετρήσεις (pH / EC / NPK…), μονάδες, reports με Excel export, αρχεία ανά
δείγμα, οικονομικά, ρόλοι & προσκλήσεις χρηστών, 2FA και audit log.

> Πρωτότυπο προϊόν. Σχεδιασμένο από γενικές έννοιες του χώρου — δεν αντιγράφει
> κώδικα, UI ή branding τρίτων.

## 🔎 Live demo (χωρίς backend)
Το [`demo/index.html`](demo/index.html) τρέχει ολόκληρη την εφαρμογή με **mock
δεδομένα** (in-memory) — χωρίς Supabase. Ιδανικό για γρήγορη περιήγηση. Μπαίνει
αυτόματα σαν platform admin· οι αλλαγές δεν αποθηκεύονται (reset στο refresh).
Ανέβασέ το σε Netlify/Vercel/Cloudflare Pages ή GitHub Pages για online link
(π.χ. `…/demo/`).

## Stack
- **Frontend:** ένα `index.html` + vanilla JS (ESM), χωρίς build.
- **Backend:** [Supabase](https://supabase.com) — PostgreSQL + Auth + Storage + Row-Level Security.
- **Libs (CDN):** `@supabase/supabase-js`, `xlsx` (SheetJS).

Η απομόνωση των πελατών επιβάλλεται στη **βάση** (RLS), όχι στο frontend.

## Δομή
```
index.html                      # όλη η εφαρμογή
lib/red3.js                     # RED III υπολογιστής GHG (καθαρό module, χωρίς DOM)
db/schema.sql                   # schema + RLS (Φάσεις 1–4, εκτός Storage)
db/seed.sql                     # default παράμετροι
db/migrations/0003_phase3.sql   # invitations + audit triggers
db/migrations/0004_phase4_storage.sql  # Storage bucket + policies (Supabase-only)
db/migrations/0010_production_integrity_roles.sql  # 1 εγγραφή παραγωγής/χωνευτή/ημέρα, όρια, admin-only ρυθμίσεις
db/migrations/0011_trends_daily_readings.sql      # συναγερμοί τάσης, ημερήσια θερμοκρασία, προγρ. στάση ΣΗΘ, σημειώσεις τροφοδοσίας
docs/DESIGN.md                  # αρχιτεκτονική, data model, roadmap
```

## Setup
1. Supabase project → `Project URL` + `anon key`.
2. SQL editor: τρέξε `db/schema.sql`, μετά `db/seed.sql`, μετά `db/migrations/0004_phase4_storage.sql`.
   Υπάρχουσα εγκατάσταση: τρέξε μόνο τις νέες migrations με τη σειρά (π.χ. `db/migrations/0010_production_integrity_roles.sql`) — είναι idempotent.
3. Signup τον εαυτό σου· `update public.profiles set is_platform_admin = true where email = '…';`
4. Άνοιξε το `index.html`, βάλε URL + anon key, login.

Αναλυτικά: [`docs/DESIGN.md`](docs/DESIGN.md).

## Κατάσταση
- ✅ Φάση 1 — Auth, Dashboard, Δείγματα/Αναλύσεις, Μαζική καταχώρηση
- ✅ Φάση 2 — Reports + Excel/CSV, διαχείριση Μονάδων & Παραμέτρων
- ✅ Φάση 3 — Χρήστες & προσκλήσεις, 2FA (TOTP), Audit log
- ✅ Φάση 4 — Αρχεία ανά δείγμα (Storage), Οικονομικά, Branding, EL/EN
- ✅ Φάση 5 — forgot-password / email-OTP login, presence, Backup, Μηνιαία αναφορά
- ✅ Φάση 6 — BioGas edition: biogas παράμετροι, μονάδες/χωνευτές, Παραγωγή + KPIs
- ✅ Φάση 7 — Υποστρώματα, Τροφοδοσία (OLR/HRT), Χώνευμα (ΖΕΝ), Ειδοποιήσεις + email
- ✅ Φάση 8 — Ισοζύγιο μάζας & ενέργειας (κλείσιμο, Van Kleeck VSR, η_el/η_th)
- ✅ Φάση 9 — Αειφορία RED III: μείωση GHG (Παράρτημα VI) έναντι ορίου άρθρου 29(10) — βλ. [`docs/RED3.md`](docs/RED3.md)
- ✅ Φάση 10 — Διορθώσεις P1 από την αξιολόγηση χειριστή (παραγωγή, σιτηρέσιο, χώνευμα, ρόλοι, ημερομηνίες) — βλ. [`docs/OPERATOR_REVIEW.md`](docs/OPERATOR_REVIEW.md) §0
- ✅ Φάση 11 — Αρχική «Σήμερα» ανά χωνευτή, διαγράμματα & συναγερμοί τάσης, σχεδιασμός που ξέρει την κατάσταση του χωνευτή

## Tests
```bash
tests/sql/run_local.sh                               # schema, RLS, alarm engine (PostgreSQL ≥ 15)
```
```bash
node --experimental-strip-types --test tests/digest.test.mjs   # alert e-mail digest
```
```bash
node --test tests/red3.test.mjs                      # RED III calculator vs official Annex VI tables
```
```bash
deno test --allow-env supabase/functions/send-alerts/handler.test.ts
```
```bash
node demo/build.js && node tests/e2e/demo_smoke.mjs  # UI end-to-end (needs: npm i -D playwright)
```
