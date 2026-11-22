# Ειδοποιήσεις μέσω email — οδηγός ενεργοποίησης

Οι συναγερμοί δημιουργούνται **αυτόματα μέσα στη βάση** (triggers) όταν μια μέτρηση,
η παραγωγή, η τροφοδοσία ή το χώνευμα βγει εκτός ορίων. Φαίνονται αμέσως στην οθόνη
**🔔 Ειδοποιήσεις** (και στο badge του μενού) — αυτό δουλεύει χωρίς καμία ρύθμιση.

Για να φεύγουν και **email**, ενεργοποιείς μία φορά το Edge Function `send-alerts`,
που κάθε 5′ μαζεύει τους νέους συναγερμούς και στέλνει **ένα συνοπτικό email ανά παραλήπτη**.

```
trigger (βάση) ──► alerts ──► pg_cron κάθε 5′ ──► Edge Function send-alerts ──► Resend ──► 📧
                                                     └─► σημειώνει emailed_at
```

## 1. Λογαριασμός αποστολής (Resend)
1. Λογαριασμός στο <https://resend.com> (δωρεάν πλάνο: 3.000 email/μήνα).
2. **Domains → Add domain** → πρόσθεσε τα DNS records (SPF/DKIM) στο domain σου.
3. **API Keys → Create** → κράτα το κλειδί (`re_…`).

## 2. Deploy του Edge Function
Με το [Supabase CLI](https://supabase.com/docs/guides/cli), από τη ρίζα του repo:

```bash
supabase link --project-ref <project-ref>
```

```bash
supabase secrets set RESEND_API_KEY=re_xxx ALERTS_FROM="BioGas Alerts <alerts@to-domain-sou.gr>" CRON_SECRET=<τυχαίο-μακρύ-string> APP_URL=https://<το-url-της-πλατφόρμας>
```

```bash
supabase functions deploy send-alerts --no-verify-jwt
```

(`--no-verify-jwt` γιατί το καλεί το cron με το `CRON_SECRET`, όχι χρήστης.)

## 3. Χρονοπρογραμματισμός (κάθε 5′)
Στο SQL editor του Supabase:

```sql
select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
select vault.create_secret('<ίδιο με το CRON_SECRET>', 'alerts_cron_secret');
```

Μετά τρέξε το `db/migrations/0008_alerts_cron.sql`.

## 4. Παραλήπτες
Στην εφαρμογή: **🔔 Ειδοποιήσεις → Παραλήπτες email** (μόνο admin). Για κάθε email
ορίζεις ελάχιστη σοβαρότητα: *Προειδοποίηση* (όλα) ή *Κρίσιμο* (μόνο κρίσιμα — π.χ. για
τον ιδιοκτήτη).

## Πώς συμπεριφέρονται οι συναγερμοί
| Κατάσταση | Τι σημαίνει | Email |
|---|---|---|
| **Ενεργός** | η συνθήκη ισχύει, κανείς δεν τον έχει δει | στέλνεται μία φορά |
| **Σε γνώση** | κάποιος πάτησε «Επιβεβαίωση» | όχι |
| **Επιλύθηκε** | η επόμενη μέτρηση γύρισε εντός ορίων (αυτόματα) | όχι |
| Κλιμάκωση | προειδοποίηση → κρίσιμο | **ξαναστέλνεται**, ακυρώνεται η «επιβεβαίωση» |
| Επανεμφάνιση | ξαναβγαίνει εκτός ορίων μετά την επίλυση | νέο email |

Ένας συναγερμός ανά συνθήκη (π.χ. «FOS/TAC — Χωνευτής 2»): αν η τιμή μένει εκτός ορίων για
μέρες, **δεν** γεμίζει το inbox — ενημερώνεται η ίδια εγγραφή.

## Έλεγχος / troubleshooting
```sql
select * from cron.job_run_details order by start_time desc limit 5;   -- τρέχει το cron;
select * from net._http_response order by created desc limit 5;       -- τι απάντησε το function;
select severity, message, emailed_at from alerts order by updated_at desc limit 10;
```
Χειροκίνητη κλήση:

```bash
curl -X POST "https://<project-ref>.supabase.co/functions/v1/send-alerts" -H "x-cron-secret: <CRON_SECRET>"
```

Απάντηση: `{"alerts":N,"emails":M,"marked":K,"failures":[]}`.

## Tests
```bash
node --experimental-strip-types --test tests/digest.test.mjs
```

```bash
deno test --allow-env supabase/functions/send-alerts/handler.test.ts
```
