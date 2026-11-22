// End-to-end test of the send-alerts handler with a stubbed network:
// PostgREST (alerts / alert_recipients / PATCH) and the Resend API.
//   deno test --allow-env supabase/functions/send-alerts/handler.test.ts
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { handler } from "./handler.ts";

const SB = "http://sb.test";
Deno.env.set("SUPABASE_URL", SB);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-key");
Deno.env.set("CRON_SECRET", "s3cret");
Deno.env.set("RESEND_API_KEY", "re_test");
Deno.env.set("ALERTS_FROM", "BioGas <alerts@example.gr>");
Deno.env.set("APP_URL", "https://app.example.gr");

const ALERTS = [
  { id: "c1", tenant_id: "A", severity: "critical", kind: "parameter", metric: "FOS/TAC", value: 0.55,
    message: "FOS/TAC = 0.55 εκτός ορίων", updated_at: "2026-11-22T06:00:00Z", unit: { name: "Χωνευτής 2" }, tenant: { name: "Βιοαέριο Α" } },
  { id: "w1", tenant_id: "A", severity: "warning", kind: "production", metric: "CH₄ %", value: 49.2,
    message: "Χαμηλό μεθάνιο 49.2%", updated_at: "2026-11-22T05:00:00Z", unit: { name: "Χωνευτής 2" }, tenant: { name: "Βιοαέριο Α" } },
];

type Call = { url: string; method: string; body: string | null };

function stubFetch(opts: { resendStatus?: number } = {}) {
  const calls: Call[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = (async (input: Request | URL | string, init?: RequestInit) => {
    const req = new Request(input, init);
    const body = req.method === "GET" ? null : await req.text();
    calls.push({ url: req.url, method: req.method, body });
    const u = new URL(req.url);
    if (u.origin === SB && u.pathname === "/rest/v1/alerts" && req.method === "GET") return Response.json(ALERTS);
    if (u.origin === SB && u.pathname === "/rest/v1/alert_recipients") {
      return Response.json([
        { tenant_id: "A", email: "ops@a.gr", min_severity: "warning", enabled: true },
        { tenant_id: "A", email: "boss@a.gr", min_severity: "critical", enabled: true },
      ]);
    }
    if (u.origin === SB && u.pathname === "/rest/v1/alerts" && req.method === "PATCH") return new Response(null, { status: 204 });
    if (u.href === "https://api.resend.com/emails") {
      const s = opts.resendStatus ?? 200;
      return s === 200 ? Response.json({ id: "email_1" }) : new Response("boom", { status: s });
    }
    return new Response("unexpected " + req.url, { status: 500 });
  }) as typeof fetch;
  return { calls, restore: () => (globalThis.fetch = original) };
}

const call = (secret = "s3cret") =>
  handler(new Request("http://fn/send-alerts", { method: "POST", headers: { "x-cron-secret": secret } }));

Deno.test("rejects requests without the cron secret", async () => {
  const net = stubFetch();
  try {
    const res = await call("wrong");
    assertEquals(res.status, 403);
    assertEquals(net.calls.length, 0);
  } finally { net.restore(); }
});

Deno.test("queries only pending alarms, e-mails each recipient, marks them e-mailed", async () => {
  const net = stubFetch();
  try {
    const res = await call();
    assertEquals(res.status, 200);
    const out = await res.json();
    assertEquals(out, { alerts: 2, emails: 2, marked: 2, failures: [] });

    const q = decodeURIComponent(net.calls.find((c) => c.method === "GET" && c.url.includes("/rest/v1/alerts"))!.url);
    for (const f of ["emailed_at=is.null", "resolved_at=is.null", "acknowledged_at=is.null", "updated_at=gte."]) {
      assertStringIncludes(q, f);
    }
    const mails = net.calls.filter((c) => c.url === "https://api.resend.com/emails").map((c) => JSON.parse(c.body!));
    assertEquals(mails.length, 2);
    const ops = mails.find((m) => m.to[0] === "ops@a.gr");
    const boss = mails.find((m) => m.to[0] === "boss@a.gr");
    assertEquals(ops.subject, "[BioGas] 1 κρίσιμο · 1 προειδοποίηση — Βιοαέριο Α");
    assertEquals(boss.subject, "[BioGas] 1 κρίσιμο — Βιοαέριο Α");
    assertEquals(ops.from, "BioGas <alerts@example.gr>");
    assertStringIncludes(ops.html, "https://app.example.gr");

    const patch = net.calls.find((c) => c.method === "PATCH")!;
    assertStringIncludes(decodeURIComponent(patch.url), "id=in.(");
    assert(JSON.parse(patch.body!).emailed_at, "emailed_at set");
  } finally { net.restore(); }
});

Deno.test("does not mark alarms when the e-mail provider fails", async () => {
  const net = stubFetch({ resendStatus: 500 });
  try {
    const res = await call();
    assertEquals(res.status, 207);
    const out = await res.json();
    assertEquals(out.marked, 0);
    assertEquals(out.failures.length, 2);
    assertEquals(net.calls.filter((c) => c.method === "PATCH").length, 0);
  } finally { net.restore(); }
});
