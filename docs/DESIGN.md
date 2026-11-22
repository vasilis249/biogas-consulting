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
| `operator` | ✅ | ✅ | ❌ | ❌ |
| `viewer` | ✅ | ❌ | ❌ | ❌ |

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
- Write μόνο για `admin`/`operator`· `viewer` = read-only.
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
- **Μελλοντικά:** email προσκλήσεων (Edge Function), ειδοποιήσεις, πλήρες EL/EN.

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
