// Pure helpers for the send-alerts Edge Function — no Deno / network APIs, so
// they are unit-tested with Node:
//   node --experimental-strip-types --test tests/digest.test.mjs

export type Severity = "warning" | "critical";

export interface AlertRow {
  id: string;
  tenant_id: string;
  severity: Severity;
  kind: string;
  metric: string | null;
  value: number | null;
  message: string | null;
  updated_at: string;
  unit?: { name: string } | null;
  tenant?: { name: string } | null;
}

export interface RecipientRow {
  tenant_id: string;
  email: string;
  min_severity: Severity;
  enabled: boolean;
}

export interface Digest {
  tenant_id: string;
  to: string;
  alertIds: string[];
  subject: string;
  html: string;
  text: string;
}

export interface DigestOptions {
  appUrl?: string;
  timeZone?: string;
}

const RANK: Record<Severity, number> = { warning: 1, critical: 2 };
const KIND_EL: Record<string, string> = {
  parameter: "Παράμετρος",
  production: "Παραγωγή",
  feeding: "Τροφοδοσία",
  digestate: "Χώνευμα",
};

export function escapeHtml(s: unknown): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

export function formatTime(iso: string, timeZone = "Europe/Athens"): string {
  return new Date(iso).toLocaleString("el-GR", {
    timeZone, day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit",
  });
}

/** "2 κρίσιμα · 1 προειδοποίηση" */
export function summarize(list: AlertRow[]): string {
  const crit = list.filter((a) => a.severity === "critical").length;
  const warn = list.length - crit;
  const parts: string[] = [];
  if (crit) parts.push(`${crit} ${crit === 1 ? "κρίσιμο" : "κρίσιμα"}`);
  if (warn) parts.push(`${warn} ${warn === 1 ? "προειδοποίηση" : "προειδοποιήσεις"}`);
  return parts.join(" · ");
}

/**
 * One digest e-mail per enabled recipient, containing that tenant's pending
 * alarms at or above the recipient's minimum severity (critical first).
 * Recipients are de-duplicated per tenant, case-insensitively.
 */
export function buildDigests(alerts: AlertRow[], recipients: RecipientRow[], opts: DigestOptions = {}): Digest[] {
  const byTenant = new Map<string, AlertRow[]>();
  for (const a of alerts) {
    const list = byTenant.get(a.tenant_id) ?? [];
    list.push(a);
    byTenant.set(a.tenant_id, list);
  }
  const out: Digest[] = [];
  const seen = new Set<string>();
  for (const r of recipients) {
    if (!r.enabled) continue;
    const email = r.email.trim().toLowerCase();
    const key = `${r.tenant_id}|${email}`;
    if (!email || seen.has(key)) continue;
    seen.add(key);
    const min = RANK[r.min_severity] ?? RANK.warning;
    const list = (byTenant.get(r.tenant_id) ?? [])
      .filter((a) => (RANK[a.severity] ?? 0) >= min)
      .sort((a, b) => RANK[b.severity] - RANK[a.severity] || a.updated_at.localeCompare(b.updated_at));
    if (!list.length) continue;
    out.push(renderDigest(r.tenant_id, email, list, opts));
  }
  return out;
}

function renderDigest(tenantId: string, to: string, list: AlertRow[], opts: DigestOptions): Digest {
  const tz = opts.timeZone ?? "Europe/Athens";
  const tenantName = list[0].tenant?.name ?? "";
  const summary = summarize(list);
  const subject = `[BioGas] ${summary}${tenantName ? ` — ${tenantName}` : ""}`;

  const rows = list.map((a) => {
    const crit = a.severity === "critical";
    const pill = `<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-weight:700;font-size:12px;`
      + `background:${crit ? "#fbe6e2" : "#fbf0dc"};color:${crit ? "#9b2d1f" : "#8a5a0b"}">${crit ? "Κρίσιμο" : "Προειδοποίηση"}</span>`;
    return `<tr>
      <td style="padding:8px 10px;border-bottom:1px solid #eee;white-space:nowrap">${pill}</td>
      <td style="padding:8px 10px;border-bottom:1px solid #eee;white-space:nowrap;color:#555">${escapeHtml(formatTime(a.updated_at, tz))}</td>
      <td style="padding:8px 10px;border-bottom:1px solid #eee">${escapeHtml(a.unit?.name ?? "—")}</td>
      <td style="padding:8px 10px;border-bottom:1px solid #eee;color:#555">${escapeHtml(KIND_EL[a.kind] ?? a.kind)}</td>
      <td style="padding:8px 10px;border-bottom:1px solid #eee">${escapeHtml(a.message ?? a.metric ?? "")}</td>
    </tr>`;
  }).join("");

  const link = opts.appUrl
    ? `<p style="margin:18px 0 0"><a href="${escapeHtml(opts.appUrl)}" style="color:#2d6a49;font-weight:700">Άνοιγμα πλατφόρμας →</a></p>`
    : "";

  const html = `<!doctype html><html lang="el"><body style="margin:0;background:#f3eee2;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#212c25">
  <div style="max-width:760px;margin:0 auto;padding:24px">
    <div style="font-weight:800;font-size:18px;margin-bottom:4px">◉ BioGas — Ειδοποιήσεις λειτουργίας</div>
    <div style="color:#69726a;margin-bottom:16px">${escapeHtml(tenantName)} · ${escapeHtml(summary)}</div>
    <table style="width:100%;border-collapse:collapse;background:#fffdf8;border:1px solid #e9e1d0;border-radius:10px;font-size:14px">
      <thead><tr style="text-align:left;color:#9aa295;font-size:12px;text-transform:uppercase">
        <th style="padding:8px 10px">Σοβαρότητα</th><th style="padding:8px 10px">Χρόνος</th><th style="padding:8px 10px">Μονάδα</th>
        <th style="padding:8px 10px">Πηγή</th><th style="padding:8px 10px">Μήνυμα</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>${link}
    <p style="color:#9aa295;font-size:12px;margin-top:18px">Λαμβάνετε αυτό το μήνυμα ως παραλήπτης ειδοποιήσεων. Η διαχείριση γίνεται από «Ειδοποιήσεις → Παραλήπτες».</p>
  </div></body></html>`;

  const text = [
    `BioGas — Ειδοποιήσεις λειτουργίας${tenantName ? ` (${tenantName})` : ""}`,
    summary,
    "",
    ...list.map((a) =>
      `[${a.severity === "critical" ? "ΚΡΙΣΙΜΟ" : "Προειδοποίηση"}] ${formatTime(a.updated_at, tz)} · ${a.unit?.name ?? "—"} · ${a.message ?? a.metric ?? ""}`),
    ...(opts.appUrl ? ["", opts.appUrl] : []),
  ].join("\n");

  return { tenant_id: tenantId, to, alertIds: list.map((a) => a.id), subject, html, text };
}
