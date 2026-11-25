/*
 * red3.js — RED III (Directive (EU) 2018/2001 as amended by 2023/2413)
 * greenhouse-gas emission-savings calculator for biogas / biomethane.
 *
 * Pure, dependency-free. Works as an ES module (import), CommonJS (require)
 * and a browser global (window.RED3). No DOM, no network, no clock except
 * where a date is passed in.
 *
 * SCOPE & HONESTY
 * ---------------
 * This implements the *default-value* pathway of Annex VI: the operator's
 * feedstock mix is mapped to the three substrate categories for which the
 * Directive publishes default values (wet manure, maize whole plant,
 * biowaste), combined by the Annex VI co-digestion energy-share weighting,
 * and compared to the Article 29(10) threshold for the plant's commissioning
 * date. Default values are deliberately conservative; a real certification
 * (actual values, ISCC/REDcert audit) will usually do better. Feedstocks
 * outside the three categories have NO Directive default — the tool flags
 * them and the result is marked as requiring an actual GHG calculation.
 *
 * Every number below is quoted from the consolidated text 02018L2001-20240716
 * (Annex VI parts A & B, Article 29). Line references are to that text.
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.RED3 = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // Fossil fuel comparators, g CO2eq/MJ (Annex V pt 19 / Annex VI). 183 for
  // electricity, 80 for useful heat/cooling, 94 for transport (biomethane).
  var FOSSIL = { electricity: 183, heat: 80, transport: 94 };

  // Annex VI co-digestion inputs. Pn = energy yield MJ biogas per kg wet feed;
  // SMn = standard moisture (kg water / kg fresh). Only the three categories
  // for which the Directive gives default values.
  var SUBSTRATE = {
    manure:   { Pn: 0.50, SM: 0.90, label: "Κτηνοτροφικά απόβλητα (κοπριά)" },
    maize:    { Pn: 4.16, SM: 0.65, label: "Ενσίρωμα (ενεργειακή καλλιέργεια)" },
    biowaste: { Pn: 3.41, SM: 0.76, label: "Βιοαπόβλητα" }
  };

  // ---- Annex VI Part A: default & typical GHG-emission SAVINGS (fraction) ----
  // BIOGAS FOR ELECTRICITY. [typical, default] per case (1/2/3) and digestate
  // storage (open / close). Source lines ~6404-6535.
  var ELEC = {
    manure:   { 1: { open: [1.46, 0.94], close: [2.46, 2.40] },
                2: { open: [1.36, 0.85], close: [2.27, 2.19] },
                3: { open: [1.42, 0.86], close: [2.43, 2.35] } },
    maize:    { 1: { open: [0.36, 0.21], close: [0.59, 0.53] },
                2: { open: [0.34, 0.18], close: [0.55, 0.47] },
                3: { open: [0.28, 0.10], close: [0.52, 0.43] } },
    biowaste: { 1: { open: [0.47, 0.26], close: [0.84, 0.78] },
                2: { open: [0.43, 0.21], close: [0.77, 0.68] },
                3: { open: [0.38, 0.14], close: [0.76, 0.66] } }
  };

  // BIOMETHANE FOR TRANSPORT (compressed). [typical, default] per digestate
  // storage and off-gas combustion. Source lines ~6704-6760.
  var BIOM = {
    manure:   { open: { no: [1.17, 0.72], yes: [1.33, 0.94] },
                close:{ no: [1.90, 1.79], yes: [2.06, 2.02] } },
    maize:    { open: { no: [0.35, 0.17], yes: [0.51, 0.39] },
                close:{ no: [0.52, 0.41], yes: [0.68, 0.63] } },
    biowaste: { open: { no: [0.43, 0.20], yes: [0.59, 0.42] },
                close:{ no: [0.70, 0.58], yes: [0.86, 0.80] } }
  };

  var CASE_NOTE = {
    1: "Η ΣΗΘ καλύπτει ρεύμα + θερμότητα της μονάδας (συνήθης διαμόρφωση)",
    2: "Ρεύμα από το δίκτυο, θερμότητα από τη ΣΗΘ",
    3: "Ρεύμα από το δίκτυο, θερμότητα από λέβητα βιοαερίου"
  };

  function round(x, d) { var f = Math.pow(10, d == null ? 2 : d); return Math.round(x * f) / f; }

  // Look up a published savings pair → return the one asked for as a fraction.
  function savingFor(substrate, opts) {
    var product = opts.product || "electricity";
    var vt = opts.valueType === "typical" ? 0 : 1; // default unless typical asked
    if (product === "electricity") {
      var c = opts.caseType || 1, dg = opts.digestate || "open";
      var row = ELEC[substrate] && ELEC[substrate][c] && ELEC[substrate][c][dg];
      return row ? row[vt] : null;
    }
    if (product === "transport") {
      var dg2 = opts.digestate || "open", og = opts.offgas || "no";
      var row2 = BIOM[substrate] && BIOM[substrate][dg2] && BIOM[substrate][dg2][og];
      return row2 ? row2[vt] : null;
    }
    return null;
  }

  // Emission value E_n (g CO2eq per MJ of final energy) for one substrate,
  // backed out of the published saving: E = EC_F · (1 − saving).
  function emissionValue(substrate, opts) {
    var s = savingFor(substrate, opts);
    if (s == null) return null;
    var ecf = (opts.product === "transport") ? FOSSIL.transport : FOSSIL.electricity;
    return ecf * (1 - s);
  }

  /*
   * Energy shares for a feedstock mix, per Annex VI Part B(b).
   *   lines: [{ substrate:'manure'|'maize'|'biowaste', massFresh:Number,
   *             moisture?:Number (kg water/kg fresh; defaults to SM) }]
   * Returns per line { substrate, Wn, Sn } where
   *   Wn = (In·(1−AMn)/(1−SMn)) / Σ      (dry-adjusted mass weighting factor)
   *   Sn = (Wn·Pn) / Σ(Wn·Pn)            (share of feedstock n in energy content)
   * Σ Wn = Σ Sn = 1. Lines with unknown substrate are returned with Sn=0 and
   * unsupported:true so the caller can refuse the default method.
   */
  function energyShares(lines) {
    var adj = lines.map(function (l) {
      var sub = SUBSTRATE[l.substrate];
      if (!sub || !(l.massFresh > 0)) return { substrate: l.substrate, unsupported: !sub, m: 0, Pn: sub ? sub.Pn : 0 };
      var am = (l.moisture == null) ? sub.SM : l.moisture;
      var m = l.massFresh * (1 - am) / (1 - sub.SM);
      return { substrate: l.substrate, unsupported: false, m: m, Pn: sub.Pn };
    });
    var sumM = adj.reduce(function (a, b) { return a + b.m; }, 0) || 1;
    adj.forEach(function (a) { a.Wn = a.m / sumM; a.e = a.Wn * a.Pn; });
    var sumE = adj.reduce(function (a, b) { return a + b.e; }, 0) || 1;
    adj.forEach(function (a) { a.Sn = a.e / sumE; });
    return adj.map(function (a) { return { substrate: a.substrate, Wn: a.Wn, Sn: a.Sn, unsupported: a.unsupported }; });
  }

  /*
   * Weighted emission & saving for a mix (default-value method).
   *   mix({ lines, product, caseType, digestate, offgas, valueType })
   * Returns { E, saving, shares, ecf, requiresActual, unsupported[] }.
   *   E       g CO2eq/MJ of final energy (electricity, or transport biomethane)
   *   saving  fraction (EC_F − E)/EC_F
   */
  function mix(cfg) {
    var lines = (cfg.lines || []).filter(function (l) { return l.massFresh > 0; });
    var product = cfg.product || "electricity";
    var ecf = product === "transport" ? FOSSIL.transport : FOSSIL.electricity;
    var shares = energyShares(lines);
    var unsupported = [];
    var E = 0, covered = 0;
    shares.forEach(function (sh) {
      if (sh.unsupported) { if (unsupported.indexOf(sh.substrate) < 0) unsupported.push(sh.substrate); return; }
      var en = emissionValue(sh.substrate, { product: product, caseType: cfg.caseType, digestate: cfg.digestate, offgas: cfg.offgas, valueType: cfg.valueType });
      E += sh.Sn * en;
      covered += sh.Sn;
    });
    var requiresActual = unsupported.length > 0;
    // If part of the energy comes from unsupported feedstocks we can only
    // report the default for the supported fraction; mark it clearly.
    var saving = covered > 0 ? (ecf - E / covered) / ecf : null;
    return {
      product: product, ecf: ecf, valueType: cfg.valueType === "typical" ? "typical" : "default",
      E: covered > 0 ? round(E / covered, 2) : null,
      saving: saving == null ? null : round(saving, 4),
      savingPct: saving == null ? null : round(saving * 100, 1),
      coveredShare: round(covered, 4),
      shares: shares, requiresActual: requiresActual, unsupported: unsupported
    };
  }

  /*
   * Article 29(10): the GHG-savings threshold a plant must meet.
   *   threshold({ commissioningDate:'YYYY-MM-DD', ratedThermalInputMW:Number,
   *               product:'electricity'|'transport', gaseous?:true,
   *               asOf?:Date|string })
   * Returns { minSavingPct, rule, clause, inScope, scopeNote, note }.
   * Rules (electricity/heating/cooling from biomass fuels), lines 1588-1602:
   *   (d) started after 2023-11-20                      → 80%
   *   (e) ≥10 MW, 2021-01-01..2023-11-20                → 70% until 2029-12-31, then 80%
   *   (f) ≤10 MW gaseous, 2021-01-01..2023-11-20        → 70% before 15 yrs operation, 80% after
   *   (g) ≥10 MW, before 2021-01-01                     → 80% after 15 yrs (earliest 2026, latest 2029-12-31)
   *   (h) ≤10 MW gaseous, before 2021-01-01             → 80% after 15 yrs (earliest 2026)
   * Transport biogas/biomethane (c): 65% from 2021-01-01.
   */
  function threshold(cfg) {
    var asOf = cfg.asOf ? new Date(cfg.asOf) : new Date();
    var product = cfg.product || "electricity";
    var mw = cfg.ratedThermalInputMW;
    var start = cfg.commissioningDate ? new Date(cfg.commissioningDate) : null;
    var D_2021 = new Date("2021-01-01"), D_2023 = new Date("2023-11-20"),
        D_2030 = new Date("2030-01-01"), D_2026 = new Date("2026-01-01"), D_2029e = new Date("2029-12-31");

    if (product === "transport") {
      var minT = 65, cl = "c";
      if (start && start < D_2021) { minT = 60; cl = "b"; }
      return { minSavingPct: minT, clause: cl, product: product, inScope: true,
        rule: minT + "% για βιομεθάνιο/βιοαέριο στις μεταφορές (άρθρο 29(10)(" + cl + "))",
        note: "Σύγκριση με ορυκτό καύσιμο μεταφορών 94 g CO₂eq/MJ." };
    }

    // Applicability (Art. 29(1), line 1465): gaseous biomass fuels in
    // installations with total rated thermal input ≥ 2 MW.
    var inScope = true, scopeNote = "";
    if (cfg.gaseous !== false && mw != null && mw < 2) {
      inScope = false;
      scopeNote = "Ονομαστική θερμική ισχύς < 2 MW: τα κριτήρια αειφορίας δεν είναι υποχρεωτικά (το κράτος-μέλος μπορεί να τα επιβάλει).";
    }

    var min = 80, clause = "d", rule;
    var yearsOp = start ? (asOf - start) / (365.25 * 864e5) : null;
    var big = (mw == null) || (mw >= 10);

    if (!start) {
      min = 80; clause = "d";
      rule = "80% (προεπιλογή — χωρίς ημ/νία έναρξης λειτουργίας)";
    } else if (start > D_2023) {
      min = 80; clause = "d";
      rule = "80% — μονάδα σε λειτουργία μετά τις 20/11/2023 (άρθρο 29(10)(d))";
    } else if (start >= D_2021) {
      if (big) {
        clause = "e";
        min = asOf >= D_2030 ? 80 : 70;
        rule = (min === 70 ? "70% έως 31/12/2029, 80% από 1/1/2030" : "80% (από 1/1/2030)") +
               " — ≥10 MW, έναρξη 2021–2023 (άρθρο 29(10)(e))";
      } else {
        clause = "f";
        min = (yearsOp != null && yearsOp >= 15) ? 80 : 70;
        rule = (min === 70 ? "70% πριν τα 15 έτη λειτουργίας, 80% μετά" : "80% (μετά 15 έτη λειτουργίας)") +
               " — ≤10 MW αέριο, έναρξη 2021–2023 (άρθρο 29(10)(f))";
      }
    } else { // before 2021
      var due = start ? new Date(start.getTime() + 15 * 365.25 * 864e5) : null;
      if (due && due < D_2026) due = D_2026;        // earliest 2026
      if (big && due && due > D_2029e) due = D_2029e; // (g) latest 2029-12-31
      var active80 = due && asOf >= due;
      clause = big ? "g" : "h";
      min = active80 ? 80 : 0;
      rule = active80
        ? ("80% — ενεργό (μονάδα προ 2021, μετά 15 έτη / " + due.toISOString().slice(0, 10) + ", άρθρο 29(10)(" + clause + "))")
        : ("Δεν ισχύει ακόμη όριο 80% — ενεργοποιείται " + (due ? due.toISOString().slice(0, 10) : "—") +
           " (μονάδα προ 2021, άρθρο 29(10)(" + clause + "))");
    }

    return { minSavingPct: min, clause: clause, product: product, inScope: inScope,
      scopeNote: scopeNote, rule: rule };
  }

  /*
   * One-call assessment: compute the mix saving and compare to the threshold.
   *   assess({ lines, product, caseType, digestate, offgas, valueType,
   *            commissioningDate, ratedThermalInputMW, gaseous, asOf,
   *            mjProduct? })
   * mjProduct (optional): MJ of final energy over the period, to report
   * tonnes CO2eq avoided = (EC_F − E) · MJ / 1e6.
   */
  function assess(cfg) {
    var m = mix(cfg);
    var th = threshold(cfg);
    var verdict = "na";
    if (m.savingPct != null && !m.requiresActual) {
      if (!th.inScope) verdict = "out_of_scope";
      else if (th.minSavingPct === 0) verdict = "no_threshold_yet";
      else verdict = m.savingPct + 1e-9 >= th.minSavingPct ? "pass" : "fail";
    } else if (m.requiresActual) {
      verdict = "requires_actual";
    }
    var avoided = null;
    if (cfg.mjProduct > 0 && m.E != null) avoided = round((m.ecf - m.E) * cfg.mjProduct / 1e6, 1);
    return {
      mix: m, threshold: th, verdict: verdict,
      marginPct: (m.savingPct != null && th.minSavingPct) ? round(m.savingPct - th.minSavingPct, 1) : null,
      avoidedTonnesCO2e: avoided,
      caseNote: cfg.product === "transport" ? null : CASE_NOTE[cfg.caseType || 1]
    };
  }

  return {
    FOSSIL: FOSSIL, SUBSTRATE: SUBSTRATE, ELEC: ELEC, BIOM: BIOM, CASE_NOTE: CASE_NOTE,
    savingFor: savingFor, emissionValue: emissionValue, energyShares: energyShares,
    mix: mix, threshold: threshold, assess: assess, round: round,
    classes: function () { return Object.keys(SUBSTRATE); }
  };
});
