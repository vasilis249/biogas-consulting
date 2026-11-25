/* ============================================================================
   BioGas DEMO — in-memory stand-in for the Supabase client (no backend).
   Injected into demo/index.html by demo/build.js.

   * Implements the subset of supabase-js the app uses (query builder, rpc,
     auth incl. MFA/OTP stubs, storage stubs).
   * Emulates the database: the feeding_daily view and the alarm triggers of
     db/migrations/0007 (same thresholds, keys and messages), so alarms appear,
     escalate and resolve while you click around.
   * Seeds a physically consistent 2-digester plant and replays ~6 weeks of
     operation in chronological order, so the alarm history is genuine.
   Data lives in memory: a page refresh restores the seed.
   ========================================================================== */
(function(){
  "use strict";
  // ---------------------------------------------------------------- utils --
  let seq = 0;
  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : "id-" + (++seq) + "-" + Math.random().toString(16).slice(2));
  const rnd = (() => { let a = 20261122; return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; })();
  const vary = (x, pct) => x * (1 + (rnd() * 2 - 1) * pct);
  const r1 = x => Math.round(x * 10) / 10, r2 = x => Math.round(x * 100) / 100, r10 = x => Math.round(x / 10) * 10;
  const NOW = new Date();
  const iso = d => d.toISOString();
  const dayAt = (daysAgo, h = 9, m = 0) => { const d = new Date(NOW); d.setDate(d.getDate() - daysAgo); d.setHours(h, m, 0, 0); return d; };
  const dateStr = daysAgo => { const d = dayAt(daysAgo, 12); return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0"); };
  const ddmmyyyy = s => s.slice(8, 10) + "/" + s.slice(5, 7) + "/" + s.slice(0, 4);
  const pgnum = v => String(v);                       // numeric::text

  // ------------------------------------------------------------- database --
  const T = "11111111-1111-1111-1111-111111111111";
  const ME = "demo-user", OP = "u-operator", CONS = "u-consultant";
  const DB = {
    tenants: [{ id: T, name: "Βιοαέριο Θεσσαλίας ΑΕ", slug: "biogas-thess", settings: { brand_color: "#2d6a49" }, created_at: iso(dayAt(400)) }],
    profiles: [
      { id: ME,   email: "demo@biogas.gr",       full_name: "Μηχανικός Λειτουργίας", role: "admin",    is_platform_admin: true,  tenant_id: T, last_seen: iso(NOW), created_at: iso(dayAt(400)) },
      { id: OP,   email: "operator@biogas.gr",   full_name: "Χειριστής Βάρδιας",     role: "operator", is_platform_admin: false, tenant_id: T, last_seen: iso(new Date(NOW - 3 * 60000)), created_at: iso(dayAt(200)) },
      { id: CONS, email: "consultant@biogas.gr", full_name: "Σύμβουλος Διεργασίας",  role: "viewer",   is_platform_admin: false, tenant_id: T, last_seen: iso(dayAt(2, 17)), created_at: iso(dayAt(90)) },
      { id: "u-new", email: "neos@biogas.gr",    full_name: "Νέος Χρήστης",          role: "viewer",   is_platform_admin: false, tenant_id: null, last_seen: null, created_at: iso(dayAt(1)) },
    ],
    parameters: [
      ["ph_dig", "pH χωνευτή", "Digester pH", "", 7.4, 8.2, 10], ["fos_tac", "FOS/TAC", "FOS/TAC", "", 0.2, 0.4, 20],
      ["temp_dig", "Θερμοκρασία χωνευτή", "Digester temp", "°C", 38, 42, 30], ["ts", "Ξηρά ουσία (TS)", "TS", "%", 7, 12, 40],
      ["vs", "Οργανική ουσία (VS)", "VS", "% TS", 70, 85, 50], ["vfa", "Πτητικά οξέα (VFA)", "VFA", "mg/l", 0, 2000, 60],
      ["nh4", "Αμμωνιακό N (NH₄-N)", "Ammonium N", "mg/l", 500, 3000, 70], ["ch4", "Μεθάνιο (CH₄)", "Methane", "%", 50, 60, 80],
      ["co2", "Διοξείδιο (CO₂)", "CO2", "%", 38, 48, 90], ["h2s", "Υδρόθειο (H₂S)", "H2S", "ppm", 0, 300, 100],
      ["o2", "Οξυγόνο (O₂)", "O2", "%", 0, 1, 110],
      ["dig_n", "Ολικό άζωτο χωνεύματος (N)", "Digestate total N", "kg/t", null, null, 120],
      ["dig_p2o5", "Φώσφορος χωνεύματος (P₂O₅)", "Digestate P2O5", "kg/t", null, null, 130],
      ["dig_k2o", "Κάλιο χωνεύματος (K₂O)", "Digestate K2O", "kg/t", null, null, 140],
    ].map(r => ({ id: "p-" + r[0], tenant_id: null, code: r[0], label_el: r[1], label_en: r[2], default_unit: r[3], ideal_min: r[4], ideal_max: r[5], sort_order: r[6], created_at: iso(dayAt(400)) })),
    feedstocks: [
      ["cattle", "Υγρή κοπριά βοοειδών", "manure", 8, 80, 210, 0, 10], ["cattle_s", "Στερεή κοπριά βοοειδών", "manure", 22, 80, 230, 0, 18],
      ["pig", "Υγρή κοπριά χοίρων", "manure", 5, 75, 300, 0, 8], ["poultry", "Κοπριά πουλερικών", "manure", 40, 75, 280, 5, 8],
      ["maize", "Ενσίρωμα αραβοσίτου", "energy_crop", 33, 95, 340, 40, 40], ["grass", "Ενσίρωμα χόρτου / τριφυλλιού", "energy_crop", 30, 90, 300, 30, 20],
      ["whey", "Τυρόγαλα (ορός γάλακτος)", "agro_industrial", 6, 85, 450, 0, 15], ["omw", "Κατσίγαρος (απόνερα ελαιοτριβείου)", "agro_industrial", 10, 80, 400, 0, 30],
      ["pomace", "Ελαιοπυρήνας (υγρός, 2 φάσεων)", "agro_industrial", 30, 90, 330, 0, 45], ["citrus", "Φλούδες εσπεριδοειδών", "agro_industrial", 20, 95, 380, 0, 30],
      ["rumen", "Περιεχόμενο στομάχων (σφαγεία)", "agro_industrial", 15, 85, 350, -10, 20], ["food", "Απόβλητα τροφίμων / εστίασης", "food_waste", 25, 90, 450, -20, 18],
      ["glycerin", "Ακατέργαστη γλυκερίνη", "other", 80, 95, 450, 50, 150],
    ].map(r => ({ id: "fs-" + r[0], tenant_id: null, name: r[1], category: r[2], ts_pct: r[3], vs_pct: r[4], bmp: r[5], price_eur_t: r[6], cn_ratio: r[7],
      notes: "Ενδεικτικές τιμές βιβλιογραφίας — επιβεβαιώστε με ανάλυση TS/VS/BMP", active: true, created_at: iso(dayAt(400)) }))
      .concat([{ id: "fs-t-sorghum", tenant_id: T, name: "Ενσίρωμα σόργου (ιδίας παραγωγής)", category: "energy_crop", ts_pct: 28, vs_pct: 93, bmp: 310,
        price_eur_t: 32, cn_ratio: 35, notes: "Ανάλυση εργαστηρίου 09/2026", active: true, created_at: iso(dayAt(70)) }]),
    units: [
      { id: "un1", tenant_id: T, name: "Χωνευτής 1", location: "Γραμμή Α", capacity_kw: 500, digester_m3: 2500, notes: "CSTR μεσόφιλος", created_at: iso(dayAt(400)) },
      { id: "un2", tenant_id: T, name: "Χωνευτής 2", location: "Γραμμή Β", capacity_kw: 999, digester_m3: 4000, notes: "CSTR μεσόφιλος", created_at: iso(dayAt(380)) },
    ],
    recipes: [], samples: [], analyses: [], production: [], feeding: [], digestate: [], files: [], audit_log: [], alerts: [],
    alert_recipients: [
      { id: "ar1", tenant_id: T, email: "demo@biogas.gr", min_severity: "warning", enabled: true, created_at: iso(dayAt(60)) },
      { id: "ar2", tenant_id: T, email: "owner@biogas.gr", min_severity: "critical", enabled: true, created_at: iso(dayAt(60)) },
      { id: "ar3", tenant_id: T, email: "consultant@biogas.gr", min_severity: "warning", enabled: false, created_at: iso(dayAt(30)) },
    ],
    invoices: [
      { id: "i1", tenant_id: T, period: dateStr(0).slice(0, 7), amount: 1200, currency: "EUR", status: "issued", issued_at: dateStr(5), notes: "Συμβουλευτική λειτουργίας", created_at: iso(dayAt(5)) },
      { id: "i2", tenant_id: T, period: dateStr(31).slice(0, 7), amount: 1200, currency: "EUR", status: "paid", issued_at: dateStr(35), notes: null, created_at: iso(dayAt(35)) },
    ],
    invitations: [{ id: "inv1", tenant_id: T, email: "vardia2@biogas.gr", role: "operator", invited_by: ME, created_at: iso(dayAt(2)), accepted_at: null }],
  };
  const F = id => DB.feedstocks.find(f => f.id === id) || {};
  const U = id => DB.units.find(u => u.id === id);
  const uname = id => (U(id) || {}).name || "—";
  const sampleUnit = sid => { const s = DB.samples.find(x => x.id === sid); return s ? (s.unit_id || null) : null; };
  DB.recipes = [
    { id: "rc1", tenant_id: T, unit_id: "un1", name: "Βασικό σιτηρέσιο — Χωνευτής 1", notes: null, created_by: ME, created_at: iso(dayAt(90)),
      items: [{ feedstock_id: "fs-maize", mass_t: 22 }, { feedstock_id: "fs-cattle", mass_t: 30 }, { feedstock_id: "fs-whey", mass_t: 8 }] },
    { id: "rc2", tenant_id: T, unit_id: "un2", name: "Βασικό σιτηρέσιο — Χωνευτής 2", notes: null, created_by: ME, created_at: iso(dayAt(90)),
      items: [{ feedstock_id: "fs-maize", mass_t: 25 }, { feedstock_id: "fs-poultry", mass_t: 9 }, { feedstock_id: "fs-pomace", mass_t: 12 },
              { feedstock_id: "fs-pig", mass_t: 35 }, { feedstock_id: "fs-food", mass_t: 3 }] },
    { id: "rc3", tenant_id: T, unit_id: "un2", name: "Χειμερινό με κατσίγαρο — Χωνευτής 2", notes: "Περίοδος ελαιοτριβείων", created_by: ME, created_at: iso(dayAt(40)),
      items: [{ feedstock_id: "fs-maize", mass_t: 22 }, { feedstock_id: "fs-poultry", mass_t: 8 }, { feedstock_id: "fs-pomace", mass_t: 10 },
              { feedstock_id: "fs-pig", mass_t: 35 }, { feedstock_id: "fs-omw", mass_t: 15 }, { feedstock_id: "fs-food", mass_t: 3 }] },
  ];

  // ------------------------------------------- alarm engine (mirrors 0007) --
  function raise(t, unit, kind, metric, value, sev, msg, key, at) {
    const ex = DB.alerts.find(a => a.dedupe_key === key);
    if (!ex) {
      DB.alerts.push({ id: uid(), tenant_id: t, unit_id: unit, kind, metric, value, severity: sev, message: msg, dedupe_key: key,
        created_at: at, updated_at: at, acknowledged_at: null, acknowledged_by: null, resolved_at: null, emailed_at: null });
      return;
    }
    const reopen = ex.resolved_at != null, escalate = ex.severity === "warning" && sev === "critical";
    Object.assign(ex, { unit_id: unit, metric, value, message: msg, severity: sev, updated_at: at });
    if (reopen) ex.created_at = at;
    if (reopen || escalate) { ex.acknowledged_at = null; ex.acknowledged_by = null; ex.emailed_at = null; }
    ex.resolved_at = null;
  }
  function clear(key, at) {
    const ex = DB.alerts.find(a => a.dedupe_key === key && a.resolved_at == null);
    if (ex) { ex.resolved_at = at; ex.updated_at = at; }
  }
  function evalParam(t, unit, param, at) {
    if (!t || !param) return;
    const key = `param:${t}:${unit || "none"}:${param}`;
    const a = DB.analyses.filter(x => x.tenant_id === t && x.parameter_id === param && sampleUnit(x.sample_id) === (unit || null))
      .sort((p, q) => String(q.measured_at || q.created_at).localeCompare(String(p.measured_at || p.created_at)) || String(q.created_at).localeCompare(String(p.created_at)))[0];
    if (!a || a.value == null) return clear(key, at);
    const p = DB.parameters.find(x => x.id === param);
    if (!p || (p.ideal_min == null && p.ideal_max == null)) return clear(key, at);
    const v = Number(a.value);
    if ((p.ideal_min != null && v < p.ideal_min) || (p.ideal_max != null && v > p.ideal_max)) {
      let span = (p.ideal_max != null && p.ideal_min != null) ? p.ideal_max - p.ideal_min : null;
      if (span == null || span <= 0) span = Math.max(Math.abs(p.ideal_max ?? p.ideal_min), 1);
      const sev = ((p.ideal_min != null && v < p.ideal_min - 0.2 * span) || (p.ideal_max != null && v > p.ideal_max + 0.2 * span)) ? "critical" : "warning";
      const s = DB.samples.find(x => x.id === a.sample_id) || {};
      raise(t, unit || null, "parameter", p.label_el || p.code, v, sev,
        `${p.label_el || p.code} = ${pgnum(v)}${a.unit ? " " + a.unit : ""} εκτός ορίων [${p.ideal_min ?? "−∞"} – ${p.ideal_max ?? "+∞"}] · ${uname(unit)} · δείγμα ${s.code || "—"}`, key, at);
    } else clear(key, at);
  }
  function evalProduction(t, unit, at) {
    if (!t) return;
    const kc = `prod-ch4:${t}:${unit || "none"}`, kp = `prod-chp:${t}:${unit || "none"}`;
    const r = DB.production.filter(x => x.tenant_id === t && (x.unit_id || null) === (unit || null))
      .sort((a, b) => String(b.log_date).localeCompare(String(a.log_date)) || String(b.created_at).localeCompare(String(a.created_at)))[0];
    if (!r) { clear(kc, at); clear(kp, at); return; }
    if (r.ch4_pct != null && r.ch4_pct < 50)
      raise(t, unit, "production", "CH₄ %", r.ch4_pct, r.ch4_pct < 45 ? "critical" : "warning",
        `Χαμηλό μεθάνιο ${pgnum(r.ch4_pct)}% στο βιοαέριο · ${uname(unit)} · ${ddmmyyyy(r.log_date)}`, kc, at);
    else clear(kc, at);
    if (r.chp_hours != null && r.chp_hours < 20)
      raise(t, unit, "production", "Ώρες ΣΗΘ", r.chp_hours, r.chp_hours < 16 ? "critical" : "warning",
        `Χαμηλή διαθεσιμότητα ΣΗΘ: ${pgnum(r.chp_hours)} ώρες (${Math.round(r.chp_hours / 24 * 100)}%) · ${uname(unit)} · ${ddmmyyyy(r.log_date)}`, kp, at);
    else clear(kp, at);
  }
  function feedingDaily() {
    const g = {};
    DB.feeding.forEach(f => {
      const k = f.tenant_id + "|" + (f.unit_id || "") + "|" + f.feed_date, fs = F(f.feedstock_id), m = Number(f.mass_t) || 0;
      const o = g[k] || (g[k] = { tenant_id: f.tenant_id, unit_id: f.unit_id, feed_date: f.feed_date, lines: 0, mass_t: 0, vs_t: 0, ch4_expected_m3: 0, cost_eur: 0 });
      const vs = m * (fs.ts_pct || 0) / 100 * (fs.vs_pct || 0) / 100;
      o.lines++; o.mass_t += m; o.vs_t += vs; o.ch4_expected_m3 += vs * (fs.bmp || 0); o.cost_eur += m * (fs.price_eur_t || 0);
    });
    return Object.values(g).map(o => { const vol = (U(o.unit_id) || {}).digester_m3;
      return { ...o, olr: vol > 0 ? o.vs_t * 1000 / vol : null, hrt: (vol > 0 && o.mass_t > 0) ? vol / o.mass_t : null }; });
  }
  function evalFeeding(t, unit, at) {
    if (!t) return;
    const ko = `olr:${t}:${unit || "none"}`, kh = `hrt:${t}:${unit || "none"}`;
    const days = feedingDaily().filter(d => d.tenant_id === t && d.unit_id === unit && unit).sort((a, b) => b.feed_date.localeCompare(a.feed_date));
    const d = days[0];
    if (!d || d.olr == null) { clear(ko, at); clear(kh, at); return; }
    if (d.olr > 4) raise(t, unit, "feeding", "OLR", r2(d.olr), d.olr > 5 ? "critical" : "warning",
      `Υψηλό οργανικό φορτίο OLR ${r2(d.olr).toFixed(2)} kg VS/m³·d (όριο 4) · ${uname(unit)} · ${ddmmyyyy(d.feed_date)}`, ko, at);
    else clear(ko, at);
    if (d.hrt != null && d.hrt < 20) raise(t, unit, "feeding", "HRT", r1(d.hrt), d.hrt < 15 ? "critical" : "warning",
      `Μικρός χρόνος παραμονής HRT ${r1(d.hrt).toFixed(1)} ημέρες (ελάχ. 20) · ${uname(unit)} · ${ddmmyyyy(d.feed_date)}`, kh, at);
    else clear(kh, at);
  }
  function evalDigestate(t, recipient, year, at) {
    const rec = String(recipient || "").trim().toLowerCase();
    if (!t || !rec || !year) return;
    const key = `dig-n:${t}:${rec}:${year}`;
    const rows = DB.digestate.filter(r => r.tenant_id === t && r.destination === "field" && String(r.recipient || "").trim().toLowerCase() === rec && String(r.log_date).slice(0, 4) === String(year));
    const n = rows.reduce((s, r) => s + (Number(r.mass_t) || 0) * (Number(r.n_kg_t) || 0), 0);
    const area = rows.reduce((m, r) => Math.max(m, Number(r.field_area_ha) || 0), 0);
    if (!area || n <= 0) return clear(key, at);
    const nha = n / area, lim = 170;
    if (nha >= lim * 0.9) raise(t, null, "digestate", "kg N/ha", r1(nha), nha > lim ? "critical" : "warning",
      `Άζωτο από χώνευμα ${r1(nha).toFixed(1)} kg N/ha το ${year} για «${String(recipient).trim()}» (όριο ΖΕΝ ${lim} kg N/ha/έτος)`, key, at);
    else clear(key, at);
  }
  // "triggers": run after every write, like the AFTER ROW triggers in SQL
  function afterWrite(table, oldRows, newRows, at) {
    const each = (rows, fn) => rows.forEach(r => r && fn(r));
    if (table === "analyses") {
      each(newRows, r => evalParam(r.tenant_id, sampleUnit(r.sample_id), r.parameter_id, at));
      each(oldRows, r => evalParam(r.tenant_id, sampleUnit(r.sample_id), r.parameter_id, at));
    } else if (table === "production") {
      each(newRows, r => evalProduction(r.tenant_id, r.unit_id, at)); each(oldRows, r => evalProduction(r.tenant_id, r.unit_id, at));
    } else if (table === "feeding") {
      each(newRows, r => evalFeeding(r.tenant_id, r.unit_id, at)); each(oldRows, r => evalFeeding(r.tenant_id, r.unit_id, at));
    } else if (table === "digestate") {
      each(newRows, r => evalDigestate(r.tenant_id, r.recipient, String(r.log_date).slice(0, 4), at));
      each(oldRows, r => evalDigestate(r.tenant_id, r.recipient, String(r.log_date).slice(0, 4), at));
    } else if (table === "units") {
      each(newRows, r => evalFeeding(r.tenant_id, r.id, at));
    } else if (table === "feedstocks") {
      each(newRows, f => [...new Set(DB.feeding.filter(x => x.feedstock_id === f.id).map(x => x.tenant_id + "|" + x.unit_id))]
        .forEach(k => { const [t, u] = k.split("|"); evalFeeding(t, u, at); }));
    }
    const AUDITED = ["units", "parameters", "samples", "analyses", "invoices", "profiles", "files", "production", "feedstocks", "recipes", "feeding", "digestate", "alert_recipients"];
    const heartbeatOnly = table === "profiles" && oldRows.length && newRows.length && newRows.every((r, i) => {
      const o = { ...oldRows[i] }, n = { ...r }; delete o.last_seen; delete n.last_seen; return JSON.stringify(o) === JSON.stringify(n); });
    if (AUDITED.includes(table) && !heartbeatOnly) {
      const action = !oldRows.length ? "insert" : (!newRows.length ? "delete" : "update");
      (newRows.length ? newRows : oldRows).forEach(r => DB.audit_log.push({ id: DB.audit_log.length + 1, tenant_id: r.tenant_id ?? null,
        user_id: currentUser, action, entity: table, entity_id: r.id, meta: {}, created_at: at }));
    }
  }
  let currentUser = ME;

  // ------------------------------------------------- seed: 6-week replay --
  const CH4_KWH = 9.97, ETA = 0.40;
  const events = [];   // {at: Date, run: fn}
  const ev = (at, run) => events.push({ at, run });
  const insertRows = (table, rows, at, user) => { currentUser = user || OP; rows.forEach(r => DB[table].push(r)); afterWrite(table, [], rows, iso(at)); };
  const mix = items => items.reduce((o, it) => { const f = F(it.feedstock_id), vs = it.mass_t * f.ts_pct / 100 * f.vs_pct / 100;
    o.vs += vs; o.ch4 += vs * f.bmp; return o; }, { vs: 0, ch4: 0 });
  const DAYS = 42;
  // digestate overflows daily to the storage tank ≈ 97 % of (feed − biogas mass), net of other removals
  // that day (sale / field), so the mass balance closes like a real plant (~3 % level / moisture drift)
  const OTHER_REMOVALS = { un2: { 20: 150, 6: 330 } };
  const NUTR = { un1: [4.6, 1.9, 5.2], un2: [5.1, 2.2, 5.6] };
  const acc = { un1: 0, un2: 0 };
  const rhoGas = ch4p => (ch4p / 100) * 0.7175 + (1 - ch4p / 100) * 1.977;
  for (let d = DAYS; d >= 1; d--) {
    for (const unit of ["un1", "un2"]) {
      let items;
      if (unit === "un1") items = [{ feedstock_id: "fs-maize", mass_t: r1(vary(22, 0.03)) }, { feedstock_id: "fs-cattle", mass_t: r1(vary(30, 0.05)) }, { feedstock_id: "fs-whey", mass_t: r1(vary(8, 0.08)) }];
      else if (d === 1) items = [{ feedstock_id: "fs-maize", mass_t: 28 }, { feedstock_id: "fs-poultry", mass_t: 9 }, { feedstock_id: "fs-pomace", mass_t: 12 },
                                 { feedstock_id: "fs-pig", mass_t: 35 }, { feedstock_id: "fs-food", mass_t: 6 }];   // overload → OLR > 4
      else items = (d <= 20 ? DB.recipes[2] : DB.recipes[1]).items.map(it => ({ ...it, mass_t: r1(vary(it.mass_t, 0.04)) }));
      const fdate = dateStr(d);
      ev(dayAt(d, 7, 30), () => insertRows("feeding", items.map(it => ({ id: uid(), tenant_id: T, unit_id: unit, feed_date: fdate,
        feedstock_id: it.feedstock_id, mass_t: it.mass_t, created_by: OP, created_at: iso(dayAt(d, 7, 30)) })), dayAt(d, 7, 30)));
      // production for that day, entered next morning
      const m = mix(items), cap = U(unit).capacity_kw;
      let eff = vary(unit === "un1" ? 0.955 : 0.945, 0.012), ch4p = r1(vary(53.2, 0.01)), chp = r1(vary(23.6, 0.008));
      if (unit === "un1" && d === 12) chp = 19.5;                                     // CHP maintenance
      if (unit === "un2" && d <= 3) { eff = { 3: 0.92, 2: 0.90, 1: 0.88 }[d]; ch4p = { 3: 51.2, 2: 50.4, 1: 49.2 }[d]; }   // acidification
      const ch4 = m.ch4 * eff, kwh = Math.min(ch4 * CH4_KWH * ETA, cap * chp);
      const at = dayAt(d - 1, 8, 10);
      ev(at, () => insertRows("production", [{ id: uid(), tenant_id: T, unit_id: unit, log_date: fdate,
        feedstock_t: r1(items.reduce((s, i) => s + i.mass_t, 0)), biogas_m3: r10(ch4 / (ch4p / 100)), ch4_pct: ch4p,
        kwh_el: r10(kwh), kwh_th: r10(kwh * 1.05), chp_hours: chp, flare_hours: 0, notes: chp < 20 ? "Συντήρηση ΣΗΘ (αλλαγή λαδιών)" : null,
        created_by: OP, created_at: iso(at) }], at));
      const feedT = items.reduce((s, i) => s + i.mass_t, 0), gasT = r10(ch4 / (ch4p / 100)) * rhoGas(ch4p) / 1000;
      acc[unit] += feedT - gasT - ((OTHER_REMOVALS[unit] || {})[d] || 0);
      const mass = Math.round(acc[unit] * 0.97);
      if (mass > 0) {                     // a deficit (big field/sale removal) carries over to the next days
        acc[unit] = 0;
        const tAt = dayAt(d, 16), [n, p, k] = NUTR[unit];
        ev(tAt, () => insertRows("digestate", [{ id: uid(), tenant_id: T, unit_id: unit, log_date: fdate, mass_t: mass,
          destination: "storage", recipient: null, field_area_ha: null, n_kg_t: n, p2o5_kg_t: p, k2o_kg_t: k,
          notes: "Υπερχείλιση χωνευτή → δεξαμενή αποθήκευσης", created_by: OP, created_at: iso(tAt) }], tAt));
      }
    }
  }
  // weekly lab samples: digester stability + gas quality (Χωνευτής 2 drifts into acidification)
  const sample = (daysAgo, unit, kind, code, vals, user) => {
    const sid = "s-" + code, at = dayAt(daysAgo, 9), res = dayAt(daysAgo, 15);
    ev(at, () => insertRows("samples", [{ id: sid, tenant_id: T, unit_id: unit, code, kind, status: "done", taken_at: dateStr(daysAgo),
      notes: null, created_by: user || OP, created_at: iso(at) }], at, user));
    ev(res, () => insertRows("analyses", Object.entries(vals).map(([c, v]) => ({ id: uid(), tenant_id: T, sample_id: sid, parameter_id: "p-" + c,
      value: v, unit: (DB.parameters.find(p => p.code === c) || {}).default_unit || null, method: null, measured_at: iso(at),
      created_by: user || OP, created_at: iso(res) })), res, user));
  };
  const wk = [35, 28, 21, 14, 7];
  wk.forEach((d, i) => {
    sample(d + 1, "un1", "digester", `D1-${String(i + 1).padStart(2, "0")}`, { ph_dig: r2(vary(7.8, 0.01)), fos_tac: r2(vary(0.27, 0.06)),
      temp_dig: i === 1 ? 37.6 : r1(vary(41, 0.01)), ts: r1(vary(9.3, 0.02)), vs: r1(vary(78, 0.01)), vfa: Math.round(vary(820, 0.08)), nh4: Math.round(vary(2100, 0.05)) });
    sample(d + 1, "un1", "biogas", `G1-${String(i + 1).padStart(2, "0")}`, { ch4: r1(vary(53.5, 0.01)), co2: r1(vary(44.5, 0.01)), h2s: Math.round(vary(180, 0.15)), o2: r1(vary(0.3, 0.2)) });
    sample(d, "un2", "digester", `D2-${String(i + 1).padStart(2, "0")}`, { ph_dig: [7.62, 7.58, 7.52, 7.47, 7.42][i], fos_tac: [0.31, 0.33, 0.36, 0.38, 0.42][i],
      temp_dig: r1(vary(40.2, 0.01)), ts: r1(vary(8.3, 0.02)), vs: r1(vary(76, 0.01)), vfa: [1100, 1300, 1600, 1900, 2300][i], nh4: Math.round(vary(2450, 0.04)) });
    sample(d, "un2", "biogas", `G2-${String(i + 1).padStart(2, "0")}`, { ch4: [53.5, 53.1, 52.8, 52.2, 51.0][i], co2: [44.1, 44.6, 45.0, 45.6, 46.8][i],
      h2s: [220, 250, 265, 300, 340][i], o2: r1(vary(0.4, 0.2)) });
  });
  sample(2, "un1", "digester", "D1-06", { ph_dig: 7.82, fos_tac: 0.27, temp_dig: 41.2, ts: 9.4, vs: 78.4, vfa: 790, nh4: 2150 });
  sample(2, "un1", "biogas", "G1-06", { ch4: 53.7, co2: 44.3, h2s: 165, o2: 0.3 });
  sample(3, "un2", "digester", "D2-06", { ph_dig: 7.35, fos_tac: 0.55, temp_dig: 40.1, ts: 8.1, vs: 75.2, vfa: 3100, nh4: 2600 });
  sample(3, "un2", "biogas", "G2-06", { ch4: 48.0, co2: 49.0, h2s: 450, o2: 0.5 });
  sample(10, "un1", "digestate", "DG1-01", { dig_n: 4.6, dig_p2o5: 1.9, dig_k2o: 5.2 });
  sample(12, "un2", "digestate", "DG2-01", { dig_n: 5.1, dig_p2o5: 2.2, dig_k2o: 5.6 });

  // digestate movements this calendar year (dates spread over the elapsed part of the year)
  const jan1 = new Date(NOW.getFullYear(), 0, 1), elapsed = Math.max(Math.floor((NOW - jan1) / 864e5), 12);
  const yearDay = frac => { const d = new Date(jan1); d.setDate(d.getDate() + Math.floor(frac * (elapsed - 8))); return d; };
  const dig = (date, unit, mass, dest, recipient, area, n, p, k) => {
    const s = date.getFullYear() + "-" + String(date.getMonth() + 1).padStart(2, "0") + "-" + String(date.getDate()).padStart(2, "0");
    const at = new Date(date); at.setHours(11, 0, 0, 0);
    ev(at, () => insertRows("digestate", [{ id: uid(), tenant_id: T, unit_id: unit, log_date: s, mass_t: mass, destination: dest, recipient,
      field_area_ha: area, n_kg_t: n, p2o5_kg_t: p, k2o_kg_t: k, notes: null, created_by: OP, created_at: iso(at) }], at));
  };
  const P1 = "Παπαδόπουλος Γ. — Αγροτεμάχιο 12", NIK = "Αγρόκτημα Νικολάου", SYN = "Συνεταιρισμός Λάρισας — Τεμ. 4";
  dig(yearDay(0.15), "un1", 120, "field", P1, 10, 4.6, 1.9, 5.2);
  dig(yearDay(0.22), "un2", 300, "field", NIK, 25, 5.1, 2.2, 5.6);
  dig(yearDay(0.30), "un1", 110, "field", P1, 10, 4.6, 1.9, 5.2);
  dig(yearDay(0.33), "un2", 280, "field", SYN, 18, 5.1, 2.2, 5.6);
  dig(yearDay(0.45), "un1", 70, "field", P1, 10, 4.6, 1.9, 5.2);
  dig(yearDay(0.72), "un2", 250, "field", NIK, 25, 5.1, 2.2, 5.6);
  dig(yearDay(0.84), "un1", 55, "field", P1, 10, 4.6, 1.9, 5.2);
  dig(dayAt(20), "un2", 150, "sale", "Λιπασματοποιία Θεσσαλίας", null, 5.1, 2.2, 5.6);
  dig(dayAt(6), "un2", 330, "field", SYN, 18, 5.1, 2.2, 5.6);      // pushes this field over 170 kg N/ha

  events.sort((a, b) => a.at - b.at).forEach(e => e.run());
  // the e-mail cron has already processed alarms older than ~10 minutes; one alarm was acknowledged by the shift operator
  DB.alerts.forEach(a => { if (!a.resolved_at && !a.acknowledged_at && (NOW - new Date(a.updated_at)) > 10 * 60000) a.emailed_at = iso(new Date(new Date(a.updated_at).getTime() + 4 * 60000)); });
  const co2 = DB.alerts.find(a => a.metric === "Διοξείδιο (CO₂)" && !a.resolved_at);
  if (co2) { co2.acknowledged_at = iso(dayAt(2, 16)); co2.acknowledged_by = OP; }
  currentUser = ME;

  // ------------------------------------------------------- query builder --
  const rel = {
    samples: r => ({ ...r, unit: U(r.unit_id) || null }),
    production: r => ({ ...r, unit: U(r.unit_id) || null }),
    alerts: r => ({ ...r, unit: U(r.unit_id) || null }),
    analyses: r => ({ ...r, parameter: DB.parameters.find(p => p.id === r.parameter_id) || null,
      sample: (() => { const s = DB.samples.find(x => x.id === r.sample_id); return s ? { ...s, unit: U(s.unit_id) || null } : null; })() }),
    audit_log: r => ({ ...r, actor: DB.profiles.find(p => p.id === r.user_id) || null }),
  };
  const VIEWS = { feeding_daily: feedingDaily };
  function run(st) {
    const t = st.table, at = iso(new Date());
    if (VIEWS[t] && st.op !== "select") return { data: null, error: { message: `cannot modify view ${t}` } };
    let rows = VIEWS[t] ? VIEWS[t]() : (DB[t] || (DB[t] = []));
    if (st.op === "insert") {
      const arr = Array.isArray(st.payload) ? st.payload : [st.payload];
      const ins = arr.map(o => ({ id: uid(), created_at: at, ...o }));
      DB[t] = rows.concat(ins); afterWrite(t, [], ins, at);
      return { data: st.single ? ins[0] : ins, error: null };
    }
    if (st.op === "update") {
      const hit = rows.filter(r => st.filters.every(f => f(r)));
      const olds = hit.map(r => ({ ...r }));
      hit.forEach(r => Object.assign(r, st.payload)); afterWrite(t, olds, hit, at);
      return { data: null, error: null };
    }
    if (st.op === "delete") {
      const gone = rows.filter(r => st.filters.every(f => f(r)));
      if (t === "feedstocks" && gone.some(f => DB.feeding.some(x => x.feedstock_id === f.id)))
        return { data: null, error: { code: "23503", message: "update or delete on table \"feedstocks\" violates foreign key constraint" } };
      DB[t] = rows.filter(r => !st.filters.every(f => f(r))); afterWrite(t, gone, [], at);
      return { data: null, error: null };
    }
    let out = rows.filter(r => st.filters.every(f => f(r)));
    const count = out.length;
    if (st.orders.length) out = out.slice().sort((a, b) => { for (const o of st.orders) { const x = a[o.c], y = b[o.c];
      if (x == null && y == null) continue; if (x == null) return o.asc ? -1 : 1; if (y == null) return o.asc ? 1 : -1;
      if (x < y) return o.asc ? -1 : 1; if (x > y) return o.asc ? 1 : -1; } return 0; });
    if (st.limit != null) out = out.slice(0, st.limit);
    out = out.map(r => rel[t] ? rel[t](r) : { ...r });
    if (st.head && st.count) return { count, data: null, error: null };
    if (st.single || st.maybeSingle) return { data: out[0] || null, error: null, count };
    return { data: out, error: null, count };
  }
  function query(table) {
    const st = { table, filters: [], orders: [], limit: null, single: false, maybeSingle: false, count: false, head: false, op: "select", payload: null };
    const add = f => { st.filters.push(f); return api; };
    const api = {
      select: (c, o) => { if (o && o.count) st.count = true; if (o && o.head) st.head = true; return api; },
      insert: r => { st.op = "insert"; st.payload = r; return api; },
      update: o => { st.op = "update"; st.payload = o; return api; },
      delete: () => { st.op = "delete"; return api; },
      eq:  (c, v) => add(r => String(r[c]) === String(v)),
      neq: (c, v) => add(r => String(r[c]) !== String(v)),
      is:  (c, v) => add(r => v === null ? r[c] == null : r[c] === v),
      not: (c, op, v) => add(r => op === "is" && v === null ? r[c] != null : String(r[c]) !== String(v)),
      gte: (c, v) => add(r => r[c] != null && r[c] >= v),
      lte: (c, v) => add(r => r[c] != null && r[c] <= v),
      lt:  (c, v) => add(r => r[c] != null && r[c] < v),
      in:  (c, vs) => add(r => vs.map(String).includes(String(r[c]))),
      or:  s => add(r => s.split(",").some(p => { const [c, op, ...rest] = p.split("."); const v = rest.join(".");
        if (op === "is" && v === "null") return r[c] == null; if (op === "eq") return String(r[c]) === v; return false; })),
      order: (c, o) => { st.orders.push({ c, asc: !(o && o.ascending === false) }); return api; },
      limit: n => { st.limit = n; return api; },
      single: () => { st.single = true; return api; },
      maybeSingle: () => { st.maybeSingle = true; return api; },
      then: (res, rej) => Promise.resolve().then(() => run(st)).then(res, rej),
    };
    return api;
  }
  function rpc(fn, args) {
    return Promise.resolve().then(() => {
      const at = iso(new Date());
      if (fn === "acknowledge_alert") {
        const a = DB.alerts.find(x => x.id === args.p_id);
        if (!a) return { data: null, error: { message: "alert not found" } };
        a.acknowledged_at = at; a.acknowledged_by = ME; a.updated_at = at;
        return { data: null, error: null };
      }
      if (fn === "replace_feeding") {
        if (!U(args.p_unit)) return { data: null, error: { message: "unknown plant" } };
        const gone = DB.feeding.filter(f => f.tenant_id === args.p_tenant && f.unit_id === args.p_unit && f.feed_date === args.p_date);
        DB.feeding = DB.feeding.filter(f => !gone.includes(f));
        const rows = (args.p_items || []).filter(i => Number(i.mass_t) > 0).map(i => ({ id: uid(), tenant_id: args.p_tenant, unit_id: args.p_unit,
          feed_date: args.p_date, feedstock_id: i.feedstock_id, mass_t: Number(i.mass_t), created_by: ME, created_at: at }));
        DB.feeding.push(...rows);
        currentUser = ME; afterWrite("feeding", gone, rows, at);
        return { data: rows.length, error: null };
      }
      return { data: null, error: { message: "unknown rpc " + fn } };
    });
  }
  const demoUser = { id: ME, email: "demo@biogas.gr" };
  const client = {
    from: query, rpc,
    auth: {
      getSession: async () => ({ data: { session: { user: demoUser } } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signInWithPassword: async () => ({ data: { user: demoUser }, error: null }),
      signUp: async () => ({ data: { user: demoUser, session: { user: demoUser } }, error: null }),
      signOut: async () => ({ error: null }),
      resetPasswordForEmail: async () => ({ data: {}, error: null }),
      signInWithOtp: async () => ({ data: {}, error: null }),
      verifyOtp: async () => ({ data: { user: demoUser }, error: null }),
      mfa: {
        getAuthenticatorAssuranceLevel: async () => ({ data: { currentLevel: "aal1", nextLevel: "aal1" } }),
        listFactors: async () => ({ data: { totp: [] } }),
        enroll: async () => ({ data: { id: "f1", totp: { qr_code: '<svg xmlns="http://www.w3.org/2000/svg" width="170" height="170"><rect width="170" height="170" fill="#e4efe3"/><text x="85" y="90" text-anchor="middle" font-size="14" fill="#2d6a49">DEMO QR</text></svg>', secret: "DEMO-SECRET" } }, error: null }),
        challenge: async () => ({ data: { id: "c1" }, error: null }),
        verify: async () => ({ error: null }),
        unenroll: async () => ({ error: null }),
      },
    },
    storage: { from: () => ({ upload: async () => ({ error: null }),
      createSignedUrl: async () => ({ data: { signedUrl: "about:blank" }, error: null }), remove: async () => ({ error: null }) }) },
  };
  window.supabase = { createClient: () => client };
  window.__BIOGAS_DEMO_DB__ = DB;   // for debugging in the console
})();
