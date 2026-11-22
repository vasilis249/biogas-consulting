// Request handler for the send-alerts Edge Function (see index.ts).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { type AlertRow, buildDigests, type RecipientRow } from "./digest.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handler(req: Request): Promise<Response> {
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret || req.headers.get("x-cron-secret") !== cronSecret) {
    return json({ error: "forbidden" }, 403);
  }
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("ALERTS_FROM");
  if (!resendKey || !from) return json({ error: "RESEND_API_KEY / ALERTS_FROM not configured" }, 500);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },   // server-side: no session, no refresh timer
  });

  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { data: alerts, error: e1 } = await sb
    .from("alerts")
    .select("id,tenant_id,severity,kind,metric,value,message,updated_at,unit:units(name),tenant:tenants(name)")
    .is("emailed_at", null)
    .is("resolved_at", null)
    .is("acknowledged_at", null)
    .gte("updated_at", since)
    .order("updated_at", { ascending: true })
    .limit(500);
  if (e1) return json({ error: e1.message }, 500);
  if (!alerts?.length) return json({ alerts: 0, emails: 0 });

  const tenantIds = [...new Set(alerts.map((a) => a.tenant_id))];
  const { data: recipients, error: e2 } = await sb
    .from("alert_recipients")
    .select("tenant_id,email,min_severity,enabled")
    .in("tenant_id", tenantIds)
    .eq("enabled", true);
  if (e2) return json({ error: e2.message }, 500);

  const digests = buildDigests(alerts as unknown as AlertRow[], (recipients ?? []) as RecipientRow[], {
    appUrl: Deno.env.get("APP_URL") ?? undefined,
  });

  const sent = new Set<string>();
  const failures: string[] = [];
  for (const d of digests) {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to: [d.to], subject: d.subject, html: d.html, text: d.text }),
    });
    if (r.ok) d.alertIds.forEach((id) => sent.add(id));
    else failures.push(`${d.to}: HTTP ${r.status} ${(await r.text()).slice(0, 300)}`);
  }

  if (sent.size) {
    const { error: e3 } = await sb.from("alerts").update({ emailed_at: new Date().toISOString() }).in("id", [...sent]);
    if (e3) failures.push(`mark e-mailed: ${e3.message}`);
  }
  return json({ alerts: alerts.length, emails: digests.length, marked: sent.size, failures }, failures.length ? 207 : 200);
}
