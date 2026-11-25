// Unit tests for lib/red3.js — verify the calculator reproduces the official
// Annex VI (Directive (EU) 2018/2001 consolidated 02018L2001-20240716) default
// and typical GHG-savings tables, and the Article 29(10) thresholds.
//   node --test tests/red3.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const RED3 = require("../lib/red3.js");

const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg}: ${a} vs ${b} (±${tol})`);

// Single substrate at default = its published default (exact by construction).
test("single-substrate reproduces Part A default savings", () => {
  const cases = [
    ["manure", 1, "open", 94], ["manure", 1, "close", 240],
    ["maize", 1, "open", 21], ["maize", 3, "close", 43],
    ["biowaste", 1, "open", 26], ["biowaste", 2, "close", 68],
  ];
  for (const [substrate, caseType, digestate, pct] of cases) {
    const r = RED3.mix({ lines: [{ substrate, massFresh: 100 }], caseType, digestate });
    near(r.savingPct, pct, 0.05, `${substrate} case${caseType} ${digestate}`);
  }
});

// The core validation: mixtures are computed from INDEPENDENT single-substrate
// values and must land on the Directive's own published mixture defaults.
test("manure-maize electricity mixtures match Annex VI (default)", () => {
  // manureFraction → { caseType: { open:[typ,def], close:[typ,def] } }
  const T = {
    0.8: { 1: { open: [72, 45], close: [120, 114] }, 2: { open: [67, 40], close: [111, 103] }, 3: { open: [65, 35], close: [114, 106] } },
    0.7: { 1: { open: [60, 37], close: [100, 94] }, 2: { open: [57, 32], close: [93, 85] }, 3: { open: [53, 27], close: [94, 85] } },
    0.6: { 1: { open: [53, 32], close: [88, 82] }, 2: { open: [50, 28], close: [82, 73] }, 3: { open: [46, 22], close: [81, 72] } },
  };
  for (const mf of [0.8, 0.7, 0.6]) {
    for (const caseType of [1, 2, 3]) {
      for (const dg of ["open", "close"]) {
        const lines = [{ substrate: "manure", massFresh: mf * 100 }, { substrate: "maize", massFresh: (1 - mf) * 100 }];
        const def = RED3.mix({ lines, caseType, digestate: dg, valueType: "default" });
        const typ = RED3.mix({ lines, caseType, digestate: dg, valueType: "typical" });
        near(def.savingPct, T[mf][caseType][dg][1], 1.0, `elec ${mf} case${caseType} ${dg} default`);
        near(typ.savingPct, T[mf][caseType][dg][0], 1.0, `elec ${mf} case${caseType} ${dg} typical`);
      }
    }
  }
});

test("manure-maize biomethane mixtures match Annex VI (default)", () => {
  // manureFraction → { 'open'|'close': { no:[typ,def], yes:[typ,def] } }
  const T = {
    0.8: { open: { no: [62, 35], yes: [78, 57] }, close: { no: [97, 86], yes: [113, 108] } },
    0.7: { open: { no: [53, 29], yes: [69, 51] }, close: { no: [83, 71], yes: [99, 94] } },
    0.6: { open: { no: [48, 25], yes: [64, 48] }, close: { no: [74, 62], yes: [90, 84] } },
  };
  for (const mf of [0.8, 0.7, 0.6]) {
    for (const dg of ["open", "close"]) {
      for (const og of ["no", "yes"]) {
        const lines = [{ substrate: "manure", massFresh: mf * 100 }, { substrate: "maize", massFresh: (1 - mf) * 100 }];
        const def = RED3.mix({ lines, product: "transport", digestate: dg, offgas: og, valueType: "default" });
        near(def.savingPct, T[mf][dg][og][1], 1.0, `biomethane ${mf} ${dg} offgas-${og} default`);
        near(def.ecf, 94, 0, "biomethane comparator");
      }
    }
  }
});

test("energy shares sum to 1 and reflect P_n weighting", () => {
  const sh = RED3.energyShares([{ substrate: "manure", massFresh: 80 }, { substrate: "maize", massFresh: 20 }]);
  near(sh.reduce((a, b) => a + b.Sn, 0), 1, 1e-9, "ΣSn");
  near(sh.reduce((a, b) => a + b.Wn, 0), 1, 1e-9, "ΣWn");
  // 20% maize by mass dominates energy because P(maize)=4.16 ≫ P(manure)=0.50
  const maize = sh.find((x) => x.substrate === "maize");
  assert.ok(maize.Sn > 0.6, `maize energy share ${maize.Sn} should exceed its 0.2 mass share`);
});

test("moisture correction changes the weighting", () => {
  const dry = RED3.energyShares([{ substrate: "manure", massFresh: 50, moisture: 0.80 }, { substrate: "maize", massFresh: 50 }]);
  const std = RED3.energyShares([{ substrate: "manure", massFresh: 50 }, { substrate: "maize", massFresh: 50 }]);
  const dm = dry.find((x) => x.substrate === "manure").Wn;
  const sm = std.find((x) => x.substrate === "manure").Wn;
  assert.ok(dm > sm, `drier manure (AM 0.80 < SM 0.90) gets more weight: ${dm} > ${sm}`);
});

test("Article 29(10) thresholds by commissioning date", () => {
  const at = (d, mw, asOf) => RED3.threshold({ commissioningDate: d, ratedThermalInputMW: mw, asOf });
  assert.equal(at("2024-03-01", 3).minSavingPct, 80, "(d) after 2023-11-20 → 80");
  assert.equal(at("2024-03-01", 3).clause, "d");
  // (e) ≥10 MW, 2021..2023
  assert.equal(at("2022-06-01", 12, "2027-01-01").minSavingPct, 70, "(e) 70% until 2029");
  assert.equal(at("2022-06-01", 12, "2031-01-01").minSavingPct, 80, "(e) 80% from 2030");
  assert.equal(at("2022-06-01", 12).clause, "e");
  // (f) ≤10 MW gaseous, 2021..2023 — 15-year hinge
  assert.equal(at("2022-06-01", 1.5, "2030-01-01").minSavingPct, 70, "(f) <15 yrs → 70");
  assert.equal(at("2022-06-01", 1.5, "2038-01-01").minSavingPct, 80, "(f) >15 yrs → 80");
  assert.equal(at("2022-06-01", 1.5).clause, "f");
  // (h) ≤10 MW before 2021 — earliest 2026
  assert.equal(at("2010-01-01", 1.0, "2025-06-01").minSavingPct, 0, "(h) before earliest → no 80 yet");
  assert.equal(at("2010-01-01", 1.0, "2027-01-01").minSavingPct, 80, "(h) after → 80");
});

test("applicability below 2 MW gaseous is out of scope", () => {
  const th = RED3.threshold({ commissioningDate: "2024-01-01", ratedThermalInputMW: 1.2, gaseous: true });
  assert.equal(th.inScope, false);
  assert.ok(/2 MW/.test(th.scopeNote));
});

test("assess gives a verdict, margin and avoided CO2", () => {
  // maize-heavy plant commissioned 2024 → 80% needed; maize default ~21% → fail.
  const fail = RED3.assess({
    lines: [{ substrate: "maize", massFresh: 90 }, { substrate: "manure", massFresh: 10 }],
    caseType: 1, digestate: "open", commissioningDate: "2024-01-01", ratedThermalInputMW: 3,
    mjProduct: 1e6,
  });
  assert.equal(fail.verdict, "fail");
  assert.ok(fail.marginPct < 0);
  assert.ok(fail.avoidedTonnesCO2e > 0, "still avoids some CO2 even when failing the threshold");

  // Manure-dominant, closed digestate → easily passes 80%.
  const pass = RED3.assess({
    lines: [{ substrate: "manure", massFresh: 95 }, { substrate: "maize", massFresh: 5 }],
    caseType: 1, digestate: "close", commissioningDate: "2024-01-01", ratedThermalInputMW: 3,
  });
  assert.equal(pass.verdict, "pass");
  assert.ok(pass.mix.savingPct > 80);
});

test("unsupported feedstock forces an actual calculation", () => {
  const r = RED3.assess({
    lines: [{ substrate: "manure", massFresh: 50 }, { substrate: "glycerol", massFresh: 50 }],
    caseType: 1, digestate: "open", commissioningDate: "2024-01-01", ratedThermalInputMW: 3,
  });
  assert.equal(r.verdict, "requires_actual");
  assert.deepEqual(r.mix.unsupported, ["glycerol"]);
});
