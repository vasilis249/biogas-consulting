-- ============================================================================
--  BioGas edition — Migration 0008: schedule the alarm e-mail digests
--  SUPABASE-ONLY (needs pg_cron, pg_net and Vault). Run after deploying the
--  Edge Function `send-alerts` — see docs/ALERTS_EMAIL.md for the full steps.
--
--  One-time, BEFORE running this file, store two secrets in Vault
--  (SQL editor; replace the values):
--
--    select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
--    select vault.create_secret('<same value as the CRON_SECRET function secret>', 'alerts_cron_secret');
-- ============================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- (re)create the job idempotently
select cron.unschedule(jobid) from cron.job where jobname = 'biogas-send-alerts';

select cron.schedule(
  'biogas-send-alerts',
  '*/5 * * * *',                       -- every 5 minutes
  $job$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
               || '/functions/v1/send-alerts',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'alerts_cron_secret')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 20000
  );
  $job$
);

-- Check: select * from cron.job where jobname = 'biogas-send-alerts';
--        select * from cron.job_run_details order by start_time desc limit 5;
--        select * from net._http_response order by created desc limit 5;
-- ============================================================================
