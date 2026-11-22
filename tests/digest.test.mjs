// Unit tests for the alarm e-mail digest builder (Edge Function send-alerts).
//   node --experimental-strip-types --test tests/digest.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildDigests, escapeHtml, summarize } from "../supabase/functions/send-alerts/digest.ts";

const A = "tenant-a", B = "tenant-b";
const alert = (id, tenant, severity, updated_at, extra = {}) => ({
  id, tenant_id: tenant, severity, kind: "parameter", metric: "FOS/TAC", value: 0.5,
  message: `msg ${id}`, updated_at, unit: { name: "Χωνευτής 1" }, tenant: { name: "Βιοαέριο Α" }, ...extra,
});
const alerts = [
  alert("w1", A, "warning", "2026-11-22T08:00:00Z"),
  alert("c1", A, "critical", "2026-11-22T09:00:00Z"),
  alert("w2", A, "warning", "2026-11-22T07:00:00Z"),
  alert("b1", B, "critical", "2026-11-22T10:00:00Z"),
];

test("one digest per recipient, filtered by minimum severity", () => {
  const d = buildDigests(alerts, [
    { tenant_id: A, email: "ops@a.gr", min_severity: "warning", enabled: true },
    { tenant_id: A, email: "boss@a.gr", min_severity: "critical", enabled: true },
  ]);
  assert.equal(d.length, 2);
  const ops = d.find((x) => x.to === "ops@a.gr");
  const boss = d.find((x) => x.to === "boss@a.gr");
  assert.deepEqual(ops.alertIds, ["c1", "w2", "w1"], "critical first, then oldest first");
  assert.deepEqual(boss.alertIds, ["c1"]);
});

test("ignores disabled recipients and other tenants' alarms", () => {
  const d = buildDigests(alerts, [
    { tenant_id: A, email: "off@a.gr", min_severity: "warning", enabled: false },
    { tenant_id: B, email: "b@b.gr", min_severity: "warning", enabled: true },
  ]);
  assert.equal(d.length, 1);
  assert.equal(d[0].to, "b@b.gr");
  assert.deepEqual(d[0].alertIds, ["b1"]);
});

test("de-duplicates recipients case-insensitively and skips empty digests", () => {
  const d = buildDigests(alerts.filter((a) => a.severity === "warning"), [
    { tenant_id: A, email: "Ops@A.gr ", min_severity: "warning", enabled: true },
    { tenant_id: A, email: "ops@a.gr", min_severity: "warning", enabled: true },
    { tenant_id: A, email: "crit@a.gr", min_severity: "critical", enabled: true },
  ]);
  assert.equal(d.length, 1);
  assert.equal(d[0].to, "ops@a.gr");
});

test("escapes HTML coming from alarm messages", () => {
  const d = buildDigests([alert("x", A, "critical", "2026-11-22T08:00:00Z", { message: '<img src=x onerror="a()">' })],
    [{ tenant_id: A, email: "a@a.gr", min_severity: "warning", enabled: true }]);
  assert.ok(!d[0].html.includes("<img"), "raw tag must not survive");
  assert.ok(d[0].html.includes("&lt;img src=x onerror=&quot;a()&quot;&gt;"));
  assert.equal(escapeHtml(`a&b'`), "a&amp;b&#39;");
});

test("Greek subject with correct plurals", () => {
  assert.equal(summarize([alert("1", A, "critical", "t")]), "1 κρίσιμο");
  assert.equal(summarize([alert("1", A, "critical", "t"), alert("2", A, "critical", "t"), alert("3", A, "warning", "t")]),
    "2 κρίσιμα · 1 προειδοποίηση");
  assert.equal(summarize([alert("1", A, "warning", "t"), alert("2", A, "warning", "t")]), "2 προειδοποιήσεις");
  const d = buildDigests(alerts, [{ tenant_id: A, email: "a@a.gr", min_severity: "warning", enabled: true }], { appUrl: "https://app.example" });
  assert.equal(d[0].subject, "[BioGas] 1 κρίσιμο · 2 προειδοποιήσεις — Βιοαέριο Α");
  assert.ok(d[0].text.includes("https://app.example"));
  assert.ok(d[0].html.includes('href="https://app.example"'));
});
