// ============================================================================
//  Supabase Edge Function: send-alerts
//  Collects pending alarms (not e-mailed, not acknowledged, not resolved,
//  updated in the last 24 h), groups them per recipient and sends one digest
//  e-mail each via Resend; marks the included alarms as e-mailed.
//
//  Invoked every 5 minutes by pg_cron (db/migrations/0008_alerts_cron.sql)
//  with header  x-cron-secret: <CRON_SECRET>.
//
//  Secrets (supabase secrets set …):
//    CRON_SECRET      shared secret, also stored in Vault for the cron job
//    RESEND_API_KEY   https://resend.com API key
//    ALERTS_FROM      e.g. "BioGas Alerts <alerts@your-domain.gr>" (verified domain)
//    APP_URL          optional, link to the platform in the e-mail
//  SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided by the platform.
//
//  Deploy: supabase functions deploy send-alerts --no-verify-jwt
// ============================================================================
import { handler } from "./handler.ts";

Deno.serve(handler);
