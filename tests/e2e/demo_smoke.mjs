// End-to-end smoke test of the BioGas demo (demo/index.html, mock backend).
//   node demo/build.js && node tests/e2e/demo_smoke.mjs        (needs: npm i -D playwright)
//   SHOTS=/some/dir node tests/e2e/demo_smoke.mjs                 → also writes screenshots
import { chromium } from "playwright";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const URL = pathToFileURL(path.join(root, "demo/index.html")).href;
const SHOTS = process.env.SHOTS;
const fails = [];
const check = (cond, msg) => { console.log(`${cond ? "  ✔" : "  ✘"} ${msg}`); if (!cond) fails.push(msg); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1320, height: 900 }, deviceScaleFactor: SHOTS ? 2 : 1 });
const errors = [];
page.on("pageerror", e => errors.push(e.message));
const dialogs = [];
let dismissNext = false;                                  // set to answer the next confirm() with «Άκυρο»
page.on("dialog", d => { dialogs.push(d.message()); if (dismissNext) { dismissNext = false; return d.dismiss(); } return d.accept(); });
const shot = async name => { if (SHOTS) await page.screenshot({ path: path.join(SHOTS, name + ".png") }); };
const db = (fn, ...args) => page.evaluate(fn, ...args);
const go = async view => { await page.click(`.nav-item[data-view="${view}"]`); await sleep(700); };
const openAlerts = () => db(() => window.__BIOGAS_DEMO_DB__.alerts.filter(a => !a.resolved_at));
const badge = () => page.$eval("#alert-badge", b => b.classList.contains("hidden") ? 0 : Number(b.textContent));

await page.goto(URL, { waitUntil: "load" });
await sleep(1200);

console.log("Σήμερα (dashboard)");
const dashTiles = await page.$$eval(".stat", s => s.map(x => [x.querySelector(".k").textContent, x.querySelector(".v").textContent]));
const activeTile = dashTiles.find(t => t[0] === "Ενεργές ειδοποιήσεις");
check(activeTile && Number(activeTile[1]) === (await openAlerts()).length, `alarm tile matches open alarms (${activeTile && activeTile[1]})`);
check(!dashTiles.some(t => /δειγμάτων|Δείγματα τον μήνα/.test(t[0])), "lab sample-count tiles removed");
check(/MWh/.test((dashTiles.find(t => t[0] === "Ηλ. ενέργεια χθες") || [])[1] || ""), "yesterday's MWh on top");
check((await page.$$("#dash-units .uc")).length === 2, "one card per digester");
const card = u => `#dash-units .uc[data-unit="${u}"]`;
check(/Κανονικά/.test(await page.textContent(`${card("un1")} .light`)) && /Κρίσιμο/.test(await page.textContent(`${card("un2")} .light`)),
  "traffic light per digester (Χ1 normal, Χ2 critical) with a text label");
const acid = await page.$eval(`${card("un2")} .uc-issues`, e => { const d = [...e.querySelectorAll("details")].find(x => /οξίνιση/.test(x.textContent));
  return d ? d.querySelectorAll("li").length : 0; });
check(acid >= 5, `Χ2 acidification signals grouped into one diagnosis (${acid} ενδείξεις)`);
check((await page.$$(`${card("un2")} svg.spark`)).length >= 6, "8-week sparklines per digester");
check(/↑/.test(await page.textContent(`${card("un2")} tr[data-code="fos_tac"]`)), "FOS/TAC shows a rising-trend arrow");
check(/kg N\/ha/.test(await page.textContent("#dash-plant")), "plant-wide alarms (digestate N) listed separately");
check((await badge()) > 0, `nav badge shows unacknowledged alarms (${await badge()})`);
await shot("1-dashboard");

console.log("Feeding planner");
await go("feeding");
check((await page.$$("#pl-lines tbody tr")).length > 0, "planner pre-loaded with the latest feeding");
check(/Βάση: τροφοδοσία/.test(await page.textContent("#pl-basis")), "basis note shown");
await page.selectOption("#pl-recipe", "rc2");
await sleep(400);
check(await page.$eval("#pl-unit", s => s.value) === "un2", "loading a recipe switches to its digester");
const tile = async k => page.$$eval(".stat", (s, k) => { const t = s.find(x => x.querySelector(".k").textContent === k);
  return t ? { v: t.querySelector(".v").textContent, c: t.querySelector(".v").style.color } : null; }, k);
const olrNormal = await tile("OLR (kg VS/m³·d)");
check(olrNormal && Math.abs(Number(olrNormal.v) - 3.94) < 0.2, `recipe OLR ≈ 3.9 (${olrNormal && olrNormal.v})`);
await shot("2-feeding-recipe");
const maizeIdx = await page.$$eval("#pl-lines .pl-fs", s => s.findIndex(x => x.value === "fs-maize"));
await page.fill(`#pl-lines .pl-mass[data-i="${maizeIdx}"]`, "40");
await sleep(300);
const olrHigh = await tile("OLR (kg VS/m³·d)");
check(Number(olrHigh.v) > 5 && olrHigh.c.includes("--high"), `overloaded mix → OLR ${olrHigh.v} shown in red`);
check(/Υψηλό οργανικό φορτίο/.test(await page.textContent("#pl-warn")), "planner explains the overload risk");
await shot("3-feeding-overload");
const today = await page.$eval("#pl-date", d => d.value);
await page.click("#pl-commit");
await sleep(600);
let olrAlarm = (await openAlerts()).find(a => a.metric === "OLR" && a.unit_id === "un2");
check(olrAlarm && olrAlarm.severity === "critical", "recording it escalates the OLR alarm to critical (server-side rule)");
check(olrAlarm && !olrAlarm.emailed_at && !olrAlarm.acknowledged_at, "escalation resets e-mail / acknowledgement state");
check((await page.$$("#fl-body tbody tr")).length > 0, "feeding log refreshed");
await page.fill(`#pl-lines .pl-mass[data-i="${maizeIdx}"]`, "25");
await sleep(200);
await page.click("#pl-commit");
// the second commit prompts a replace-confirm; wait for the mock to reflect it rather than guessing a delay
let fedToday = 0;
for (let i = 0; i < 20; i++) {
  const m = await db(t => { const r = window.__BIOGAS_DEMO_DB__.feeding.filter(f => f.unit_id === "un2" && f.feed_date === t);
    return { n: r.length, maize: (r.find(x => x.feedstock_id === "fs-maize") || {}).mass_t }; }, today);
  fedToday = m.n;
  if (m.n === 5 && m.maize === 25) break;
  await sleep(150);
}
check(fedToday === 5, `re-recording the same day replaces it (5 rows, got ${fedToday})`);
olrAlarm = (await openAlerts()).find(a => a.metric === "OLR" && a.unit_id === "un2");
check(!olrAlarm, "back to OLR 3.9 → OLR alarm resolved automatically");

console.log("Feedstocks");
await go("feedstocks");
check((await page.$$("#fs-body tbody tr")).length >= 14, "registry lists global + own feedstocks");
await page.click('#fs-body [data-copy="fs-maize"]');
await sleep(300);
check(/m³ CH₄ \/ t/.test(await page.textContent("#fs-yield")), "live methane-yield preview in the form");
await page.fill("#fs-ts", "35");
await page.click(".modal .foot .btn.primary");
await sleep(600);
const own = await db(() => window.__BIOGAS_DEMO_DB__.feedstocks.filter(f => f.tenant_id && f.name === "Ενσίρωμα αραβοσίτου").length);
check(own === 1, "«Προσαρμογή» creates the tenant's own version");
await shot("4-feedstocks");

console.log("Digestate");
await go("digestate");
check((await page.$$("#dg-ytd tbody tr")).length === 3, "yearly nitrogen balance per recipient");
const digBefore = await db(() => window.__BIOGAS_DEMO_DB__.digestate.length);
await page.click("#dg-new");
await sleep(500);
check((await page.inputValue("#dgf-n")) !== "", "nutrients pre-filled from the latest digestate analysis");
await page.fill("#dgf-mass", "40");
await page.fill("#dgf-rec", "Αγρόκτημα Νικολάου");
await page.fill("#dgf-area", "25");
await page.click(".modal .foot .btn.primary");
await sleep(600);
check((await db(() => window.__BIOGAS_DEMO_DB__.digestate.length)) === digBefore + 1, "digestate movement recorded");
await shot("5-digestate");

console.log("Mass & energy balance");
await go("massbalance");
await sleep(300);
const mbTile = async k => page.$$eval(".stat", (s, k) => { const t = s.find(x => x.querySelector(".k").textContent === k);
  return t ? t.querySelector(".v").textContent : null; }, k);
// previous full month: complete feeding / production / weekly digestate transfers
const prevMonth = await page.evaluate(() => { const d = new Date(); d.setDate(1); d.setMonth(d.getMonth() - 1); return d.toISOString().slice(0, 7); });
await page.fill("#mb-month", prevMonth);
await page.dispatchEvent("#mb-month", "change");
await sleep(700);
const closure = parseFloat(await mbTile("Κλείσιμο ισοζυγίου"));
check(closure > 85 && closure < 110, `mass balance closes for ${prevMonth} (${closure}%)`);
const eta = parseFloat(await mbTile("η ηλεκτρ. ΣΗΘ"));
check(Math.abs(eta - 40) < 1.5, `CHP electrical efficiency from metered data ≈ 40% (${eta}%)`);
const vsr = parseFloat(await mbTile("Απομάκρυνση VS"));
check(vsr > 30 && vsr < 85, `VS removal (Van Kleeck) computed (${vsr}%)`);
check(!!(await page.$("#mb-flow svg")), "mass-flow diagram rendered");
check((await page.$$("#mb-feed tbody tr")).length >= 5, "inputs broken down by feedstock");
await page.selectOption("#mb-unit", "un1");
await sleep(600);
const u1 = parseFloat(await mbTile("Απομάκρυνση VS"));
check(u1 > vsr, `healthy Χωνευτής 1 removes more VS than the plant average (${u1}% > ${vsr}%)`);
await shot("5b-mass-balance");

console.log("Sustainability (RED III)");
await go("red3");
await sleep(300);
const r3Tile = async k => page.$$eval(".stat", (s, k) => { const t = s.find(x => x.querySelector(".k").textContent === k);
  return t ? t.querySelector(".v").textContent : null; }, k);
const r3Saving = async () => { const v = (await r3Tile("Μείωση GHG (τμήμα)")) || (await r3Tile("Μείωση GHG")); return v ? parseFloat(v) : null; };
await page.selectOption("#r3-unit", "un2");                   // commissioned 2024 → 80% threshold
await sleep(700);
check((await r3Tile("Όριο 29(10)")) === "80%", `2024 plant → Article 29(10) threshold 80% (${await r3Tile("Όριο 29(10)")})`);
check(/άρθρο 29\(10\)\(d\)/.test(await page.textContent("#r3-thr")), "threshold rule cites the commissioning-date clause");
check((await page.$$("#r3-mix tbody tr")).length >= 3, "feedstock mix broken down by RED III class");
check(/maize whole plant/.test(await page.textContent("#r3-mix")), "maize class carries its Annex VI default emission value");
const savOpen = await r3Saving();
check(savOpen > 0 && savOpen < 100, `default-method GHG saving computed for the supported mix (${savOpen}%)`);
check(/Απαιτείται πραγματικός υπολογισμός/.test(await page.textContent("#r3-verdict")), "non-default feedstocks flag an actual-calculation requirement");
await shot("8-red3");
await page.selectOption("#r3-dgst", "close");                // gas-tight storage ⇒ higher saving
await sleep(600);
const savClose = await r3Saving();
check(savClose > savOpen, `gas-tight digestate raises the saving (${savOpen}% → ${savClose}%)`);
check((await page.$$("#r3-scen tbody tr")).length === 2, "scenario grid compares open vs close storage");
await page.selectOption("#r3-unit", "un1");                   // pre-2021 small plant → 80% not in force yet
await sleep(700);
check((await r3Tile("Όριο 29(10)")) === "—" && /Δεν ισχύει ακόμη/.test(await page.textContent("#r3-thr")),
  "pre-2021 plant: 80% threshold not yet in force (Article 29(10)(h))");

console.log("Alarms");
await go("alerts");
const before = await badge();
check((await page.$$eval("#al-body thead th", h => h.map(x => x.textContent))).includes("Από"), "alarm list shows «since when» (created_at)");
const ackId = await page.$eval("[data-ack]", b => b.dataset.ack);
await page.click("[data-ack]");
await sleep(300);
await page.fill("#ack-c", "Ενημερώθηκε ο μηχανικός — νέο FOS/TAC αύριο");
await page.click(".modal .foot .btn.primary");
await sleep(600);
check((await badge()) === before - 1, `acknowledging decrements the badge (${before} → ${await badge()})`);
const acked = await db(id => window.__BIOGAS_DEMO_DB__.alerts.find(a => a.id === id), ackId);
check(acked.ack_comment === "Ενημερώθηκε ο μηχανικός — νέο FOS/TAC αύριο" && !!acked.acknowledged_by, "acknowledgement stores who and the comment");
check(/Ενημερώθηκε ο μηχανικός/.test(await page.textContent("#al-body")), "comment shown in the alarm list");
await page.click('[data-af="all"]');
await sleep(500);
check(/Επιλύθηκε/.test(await page.textContent("#al-body")), "history shows resolved alarms");
check((await page.$$("#al-recips tbody tr")).length === 3, "e-mail recipients listed");
await page.click('[data-af="open"]');
await sleep(400);
await shot("6-alerts");

console.log("Operator review — P1 fixes");
const waitFor = async (fn, ms = 3000) => { for (let t = 0; t < ms; t += 100) { if (await fn()) return true; await sleep(100); } return false; };
// (1) planner: switching digester loads THAT digester's latest ration
await go("feeding");
const latestIds = unit => db(u => { const F = window.__BIOGAS_DEMO_DB__.feeding.filter(f => f.unit_id === u);
  const last = F.map(f => f.feed_date).sort().pop(); return F.filter(f => f.feed_date === last).map(f => f.feedstock_id).sort().join(","); }, unit);
const planIds = () => page.$$eval("#pl-lines .pl-fs", s => s.map(x => x.value).sort().join(","));
await page.selectOption("#pl-unit", "un1");
await waitFor(async () => (await planIds()) === (await latestIds("un1")));
check((await planIds()) === (await latestIds("un1")), "switching to Χωνευτής 1 loads its own latest ration");
check(/Χωνευτής 1/.test(await page.textContent("#pl-basis")), "basis note names the selected digester");
const olr1 = (await tile("OLR (kg VS/m³·d)")).v;
await page.selectOption("#pl-unit", "un2");
await waitFor(async () => (await planIds()) === (await latestIds("un2")));
check((await planIds()) === (await latestIds("un2")), "switching back to Χωνευτής 2 replaces the lines (no carry-over)");
check((await tile("OLR (kg VS/m³·d)")).v !== olr1, `OLR recomputed for the selected digester (${olr1} → ${(await tile("OLR (kg VS/m³·d)")).v})`);

// (2)(3) production form: limits, flare hours, one log per digester/day, default = yesterday
await go("production");
check((await page.$$eval("#pr-body thead th", h => h.map(x => x.textContent))).includes("Ώρες πυρσού"), "production table shows flare hours");
const yesterday = await page.evaluate(() => daysAgoDate(1));
const prodRows = (u, d) => db(({ u, d }) => window.__BIOGAS_DEMO_DB__.production.filter(r => r.unit_id === u && r.log_date === d), { u, d });
const prodCount = () => db(() => window.__BIOGAS_DEMO_DB__.production.length);
const nProd = await prodCount();
await page.click("#pr-new");
await sleep(300);
check((await page.inputValue("#prf-date")) === yesterday, `new log defaults to yesterday (${yesterday})`);
await page.selectOption("#prf-u", "un1");
await page.fill("#prf-ch4", "531"); await page.fill("#prf-h", "31"); await page.fill("#prf-gas", "-500"); await page.fill("#prf-el", "1080000");
await page.click(".modal .foot .btn.primary");
await sleep(300);
const prodErr = await page.textContent("#prf-msg");
check(/CH₄ 531/.test(prodErr) && /Ώρες ΣΗΘ 31/.test(prodErr) && /αρνητικό/.test(prodErr) && /μέγιστο δυνατό της ΣΗΘ/.test(prodErr),
  "typos rejected with a reason each (CH₄ 531 %, 31 h, −500 m³, 1.08 GWh on a 500 kW CHP)");
check((await prodCount()) === nProd && !!(await page.$(".modal")), "nothing saved, form stays open for correction");
await page.fill("#prf-ch4", "52.8"); await page.fill("#prf-h", "21"); await page.fill("#prf-gas", "9800"); await page.fill("#prf-el", "10200");
await page.fill("#prf-flare", "2.5");
dialogs.length = 0;
dismissNext = true;                                        // «Άκυρο» on the replace prompt → nothing changes
await page.click(".modal .foot .btn.primary");
await sleep(400);
check(dialogs.some(m => /Υπάρχει ήδη εγγραφή/.test(m) && /Αντικατάσταση/.test(m)), "existing day → «replace?» prompt");
check((await prodRows("un1", yesterday))[0].flare_hours !== 2.5, "declining the prompt keeps the existing log");
await page.click(".modal .foot .btn.primary");               // accept this time
await waitFor(async () => !(await page.$(".modal")));
const rowsY = await prodRows("un1", yesterday);
check(rowsY.length === 1 && rowsY[0].flare_hours === 2.5 && rowsY[0].ch4_pct === 52.8, "accepting replaces it — still one log, flare hours stored");
check((await prodCount()) === nProd, `no duplicate production rows (${await prodCount()} = ${nProd})`);
const dbDup = await page.evaluate(async d => (await sb.from("production").insert({ tenant_id: state.tenantId, unit_id: "un1", log_date: d })).error, yesterday);
check(dbDup && dbDup.code === "23505", "backend rejects a second log for the same digester/day (unique key)");
const dbChk = await page.evaluate(async () => (await sb.from("production").insert({ tenant_id: state.tenantId, unit_id: "un1", log_date: "2020-01-01", ch4_pct: 531 })).error);
check(dbChk && dbChk.code === "23514", "backend rejects CH₄ 531 % (check constraint)");

// (4) dates follow the plant's clock, not UTC (night shift at 00:30 Athens time)
{
  const ctx = await browser.newContext({ timezoneId: "Europe/Athens" });
  const p2 = await ctx.newPage();
  await p2.goto(URL, { waitUntil: "load" });
  await sleep(800);
  const r = await p2.evaluate(() => { const t = new Date("2026-11-24T22:30:00Z"); return { local: localDate(t), utc: t.toISOString().slice(0, 10) }; });
  check(r.local === "2026-11-25" && r.utc === "2026-11-24", `00:30 Athens → ${r.local} (UTC would give ${r.utc})`);
  await ctx.close();
}

// (5) digestate: warn BEFORE exceeding 170 kg N/ha
await go("digestate");
const nDig = await db(() => window.__BIOGAS_DEMO_DB__.digestate.length);
await page.click("#dg-new");
await sleep(500);
await page.selectOption("#dgf-dest", "field");
await page.fill("#dgf-rec", "Συνεταιρισμός Λάρισας — Τεμ. 4");
await page.fill("#dgf-mass", "200");
await sleep(200);
const ytdHint = await page.textContent("#dgf-ytd");
check(/Υπέρβαση ορίου/.test(ytdHint) && /του ορίου 170/.test(ytdHint), `form shows the year total incl. this application (${(ytdHint.match(/= ([\d.]+ kg N\/ha)/) || [])[1]})`);
dialogs.length = 0;
dismissNext = true;
await page.click(".modal .foot .btn.primary");
await sleep(400);
check(dialogs.some(m => /kg N\/ha/.test(m) && /Αποθήκευση παρόλα αυτά/.test(m)), "saving over the limit asks for confirmation");
check((await db(() => window.__BIOGAS_DEMO_DB__.digestate.length)) === nDig, "declining keeps the application unsaved");
dialogs.length = 0;
await page.fill("#dgf-rec", "Παπαδόπουλος Γ. — Αγροτεμάχιο 12");
await page.fill("#dgf-mass", "5");
await sleep(150);
check(!/Υπέρβαση/.test(await page.textContent("#dgf-ytd")), "a field within the limit shows no excess warning");
await page.click(".modal .foot .btn.primary");
await waitFor(async () => !(await page.$(".modal")));
check(dialogs.length === 0 && (await db(() => window.__BIOGAS_DEMO_DB__.digestate.length)) === nDig + 1, "within the limit → saved without a prompt");

// (6) operators cannot change digesters or alarm limits (mirrors RLS of 0010)
await page.evaluate(() => { state.profile = { ...state.profile, role: "operator", is_platform_admin: false }; });
await go("units");
check(!(await page.$("#btn-new-unit")) && !(await page.$("#units-body [data-del]")) && !(await page.$("#units-body [data-edit]")), "operator: no create/edit/delete on digesters");
await go("params");
check(!(await page.$("#btn-new-param")) && !(await page.$("#params-body [data-copy]")), "operator: alarm limits are read-only");
await go("production");
check(!!(await page.$("#pr-new")), "operator still records production");
await page.evaluate(() => { state.profile = { ...state.profile, role: "admin", is_platform_admin: true }; });
await go("units");
check(!!(await page.$("#units-body [data-del]")), "admin keeps digester management");

// (7) an invisible toast never swallows taps
check((await page.$eval("#toast", t => getComputedStyle(t).pointerEvents)) === "none", "toast has pointer-events:none");
await shot("9-production-form");

console.log("Wave A — trends, state-aware planner, daily readings");
const allAlerts = () => db(() => window.__BIOGAS_DEMO_DB__.alerts);
{
  const A = await allAlerts();
  const trend = A.find(a => a.unit_id === "un2" && a.metric === "FOS/TAC (τάση)");
  const abs = A.find(a => a.unit_id === "un2" && a.metric === "FOS/TAC");
  check(!!trend && !trend.resolved_at, "FOS/TAC trend alarm open on Χ2");
  check(trend && abs && trend.created_at < abs.created_at,
    `trend alarm came before the absolute one (${trend && trend.created_at.slice(0, 10)} < ${abs && abs.created_at.slice(0, 10)})`);
  check(A.some(a => a.unit_id === "un2" && a.metric === "CH₄ % (τάση)" && !a.resolved_at), "falling-CH₄ (3 days) alarm on Χ2");
  check(!A.some(a => a.unit_id === "un1" && a.metric === "Ώρες ΣΗΘ"), "planned CHP maintenance on Χ1 raised no availability alarm");
}
await go("feeding");
await page.selectOption("#pl-unit", "un2");
await waitFor(async () => /Ασταθής/.test(await page.textContent("#pl-state")));
check(/Ασταθής/.test(await page.textContent("#pl-state")) && /FOS\/TAC/.test(await page.textContent("#pl-state")), "planner shows Χ2 is unstable next to OLR/HRT");
await waitFor(async () => (await page.$$("#pl-lines .pl-mass")).length > 0);
for (const el of await page.$$("#pl-lines .pl-mass")) { const v = Number(await el.inputValue()); await el.fill(String(Math.round(v * 0.6 * 10) / 10)); }
await sleep(300);
const planInfo = (await page.$("#pl-info")) ? await page.textContent("#pl-info") : "";
check(/σωστή κίνηση/.test(planInfo) && !/σταδιακή/.test(await page.textContent("#pl-warn")), "cutting an unstable digester is endorsed, not warned against");
check(/εύπεπτα/.test(planInfo), "planner suggests cutting the fast-acidifying substrates first");
await page.fill("#pl-note", "Κόψιμο 40% λόγω FOS/TAC 0,55");
await page.click("#pl-commit");
await waitFor(async () => (await db(() => window.__BIOGAS_DEMO_DB__.feeding_notes.filter(n => n.unit_id === "un2").length)) >= 3);
const today2 = await page.$eval("#pl-date", d => d.value);
check(await db(t => (window.__BIOGAS_DEMO_DB__.feeding_notes.find(n => n.unit_id === "un2" && n.feed_date === t) || {}).note === "Κόψιμο 40% λόγω FOS/TAC 0,55", today2),
  "the reason for the change is stored with the feeding day");
await waitFor(async () => /Κόψιμο 40%/.test(await page.textContent("#fl-body")));
check(/📝 Κόψιμο 40%/.test(await page.textContent("#fl-body")), "feeding log shows the note");

await go("production");
check((await page.$$eval("#pr-body thead th", h => h.map(x => x.textContent))).includes("°C"), "production table shows the daily temperature");
const todayD = await page.evaluate(() => localDate());
await page.click("#pr-new"); await sleep(300);
await page.fill("#prf-date", todayD); await page.selectOption("#prf-u", "un2");
await page.fill("#prf-ch4", "49"); await page.fill("#prf-h", "23"); await page.fill("#prf-temp", "38");
await page.click(".modal .foot .btn.primary");
await waitFor(async () => !(await page.$(".modal")));
const tAl = (await openAlerts()).find(a => a.unit_id === "un2" && a.metric === "Θερμοκρασία χωνευτή");
check(tAl && tAl.severity === "critical" && /έλεγχος θέρμανσης/.test(tAl.message), `−2 °C in a day → critical heating alarm (${tAl && tAl.message.slice(0, 60)}…)`);
await page.click("#pr-new"); await sleep(300);
await page.fill("#prf-date", todayD); await page.selectOption("#prf-u", "un1");
await page.fill("#prf-h", "12"); await page.check("#prf-planned");
await page.click(".modal .foot .btn.primary");
await waitFor(async () => !(await page.$(".modal")));
check(!(await openAlerts()).some(a => a.unit_id === "un1" && a.metric === "Ώρες ΣΗΘ"), "12 h with «προγραμματισμένη στάση» → no CHP alarm");
check(/🔧/.test(await page.textContent("#pr-body")), "planned stop marked in the production list");

await go("params");
check(/\+0,05 σε 14 ημ\./.test(await page.textContent("#params-body")), "FOS/TAC trend rule visible in Parameters");
await shot("10-today");

console.log("Wave B — shift, incidents, emergency, maintenance");
await go("dashboard");
check(/Φίλτρο ενεργού άνθρακα \(αποθείωση\): οφείλεται/.test(await page.textContent(`${card("un2")}`)), "Σήμερα: overdue CHP service shown on Χ2");
check(/📌 Εκκρεμότητες/.test(await page.textContent(`${card("un2")}`)), "Σήμερα: open shift items shown per digester");

await go("shift");
await waitFor(async () => /Αυτόματη σύνοψη/.test(await page.textContent("#sh-summary")));
await page.selectOption("#sh-shift", "morning");
await page.fill("#sh-date", await page.evaluate(() => daysAgoDate(1)));
await page.dispatchEvent("#sh-date", "change");
await waitFor(async () => /Τροφοδοσία|Συναγερμός|Παραγωγή/.test(await page.textContent("#sh-summary")));
check(/Τροφοδοσία|Συναγερμός|Παραγωγή/.test(await page.textContent("#sh-summary")), "automatic shift summary lists what happened in that shift");
await page.click("#sh-addsum");
await page.fill("#sh-body", (await page.inputValue("#sh-body")) + "\nΠαραδίδω: Χ2 υπό παρακολούθηση.");
const nLog = await db(() => window.__BIOGAS_DEMO_DB__.shift_log.length);
await page.click("#sh-save");
await waitFor(async () => (await db(() => window.__BIOGAS_DEMO_DB__.shift_log.length)) === nLog + 1);
const lastLog = await db(() => window.__BIOGAS_DEMO_DB__.shift_log.slice(-1)[0]);
check(lastLog.shift === "morning" && /Σύνοψη/.test(lastLog.body) && /Παραδίδω/.test(lastLog.body), "hand-over saved with the summary and the note");
await page.fill("#tk-title", "Έλεγχος στάθμης δεξαμενής χωνεύματος");
await page.click("#tk-add");
await waitFor(async () => /στάθμης δεξαμενής/.test(await page.textContent("#sh-tasks")));
check((await page.$$("#sh-tasks li")).length === 3, "open items carry over (2 from earlier shifts + 1 new)");
await page.click('#sh-tasks li:first-child [data-done]');
await waitFor(async () => (await page.$$("#sh-tasks li")).length === 2);
check((await db(() => window.__BIOGAS_DEMO_DB__.shift_tasks.filter(t => t.done_at).length)) === 1, "«✓ Έγινε» closes an item");

await go("incidents");
check(/Trip ΣΗΘ/.test(await page.textContent("#inc-body")) && /1 h 15/.test(await page.textContent("#inc-body")), "past incident listed with its duration");
await page.click("#inc-new"); await sleep(300);
await page.selectOption("#if-kind", "gas_leak"); await page.selectOption("#if-sev", "emergency"); await page.selectOption("#if-unit", "un2");
await page.fill("#if-title", "Μυρωδιά αερίου στο αντλιοστάσιο Χ2");
await page.click(".modal .foot .btn.primary");
await waitFor(async () => !(await page.$(".modal")));
let incAl = (await openAlerts()).find(a => a.kind === "incident");
check(incAl && incAl.severity === "critical" && /ΕΚΤΑΚΤΗ ΑΝΑΓΚΗ ΣΕ ΕΞΕΛΙΞΗ/.test(incAl.message), "emergency incident in progress → critical alarm for everyone");
await page.click('#inc-body tbody tr:first-child [data-iedit]'); await sleep(300);
await page.click("#if-now"); await page.fill("#if-act", "Απομόνωση, έλεγχος με ανιχνευτή, σφίξιμο φλάντζας.");
await page.click(".modal .foot .btn.primary");
await waitFor(async () => !(await page.$(".modal")));
check(!(await openAlerts()).some(a => a.kind === "incident"), "closing the incident resolves its alarm");
const [popup] = await Promise.all([page.waitForEvent("popup"), page.click('#inc-body tbody tr:first-child [data-irep]')]);
await popup.waitForLoadState();
check(/Αναφορά συμβάντος/.test(await popup.textContent("body")) && /σφίξιμο φλάντζας/.test(await popup.textContent("body")), "printable incident report (PDF via print)");
await popup.close();

await go("emergency");
check((await page.$$("#em-cards details")).length === 8, "8 emergency cards (from db/seed.sql)");
check(!!(await page.$('#em-contacts a[href="tel:112"]')) && !!(await page.$('#em-contacts a[href="tel:199"]')), "one-tap call buttons (tel:)");
const firstCall = await page.$eval("#em-contacts .contact:first-child .call", e => e.textContent);
check(/112/.test(firstCall), "emergency numbers listed first");
await page.click('#em-cards details[data-scenario="gas_leak"] summary');
check(/ATEX/.test(await page.textContent('#em-cards details[data-scenario="gas_leak"]')), "card opens with its steps");
await page.click('#em-cards details[data-scenario="gas_leak"] [data-card]'); await sleep(300);
await page.fill("#cf-steps", "Βήμα της μονάδας 1\nΒήμα της μονάδας 2");
await page.click(".modal .foot .btn.primary");
await waitFor(async () => /της μονάδας/.test(await page.textContent('#em-cards details[data-scenario="gas_leak"]')));
check((await db(() => window.__BIOGAS_DEMO_DB__.emergency_cards.filter(c => c.scenario === "gas_leak").length)) === 2, "«Προσαρμογή» keeps the template and adds the plant's own card");

await go("maintenance");
check(/Οφείλεται/.test(await page.textContent("#mt-body")) && /ΟΚ/.test(await page.textContent("#mt-body")), "service status by running hours (due / ok)");
check(/υπέρβαση/.test(await page.textContent("#mt-body")), "overdue shows hours over the interval");
check(await page.evaluate(() => [maintState({ hours_left: 9, interval_hours: 1000 }), maintState({ hours_left: 500, interval_hours: 1000 }), maintState({ hours_left: -1, interval_hours: 1000 })].join()) === "warn,ok,crit",
  "«σύντομα» = last 10 % of the interval (min 50 h)");
await page.click('#mt-body [data-mdone="mp4"]'); await sleep(300);
await page.fill("#sf-notes", "Αλλαγή ενεργού άνθρακα 2 m³");
await page.click(".modal .foot .btn.primary");
await waitFor(async () => (await db(() => window.__BIOGAS_DEMO_DB__.maintenance_log.length)) === 2);
check(await db(() => window.__BIOGAS_DEMO_DB__.maintenance_plans.find(p => p.id === "mp4").last_done_on) === await page.evaluate(() => localDate()),
  "logging the service resets its hour counter");
await page.evaluate(() => { state.profile = { ...state.profile, role: "operator", is_platform_admin: false }; });
await go("emergency");
check(!(await page.$("#ct-new")) && !(await page.$("#em-cards [data-card]")), "operator: contacts & cards read-only");
await go("maintenance");
check(!(await page.$("#mt-new")) && !!(await page.$("#mt-body [data-mdone]")), "operator logs services but cannot change plans");
await page.evaluate(() => { state.profile = { ...state.profile, role: "admin", is_platform_admin: true }; });
await shot("11-emergency");

console.log("English & mobile");
await page.evaluate(() => localStorage.setItem("lp-lang", "en"));
await page.reload({ waitUntil: "load" });
await sleep(1200);
const nav = await page.$$eval(".nav-item[data-view]", n => n.map(x => x.textContent));
check(["Feeding", "Digestate", "Alerts", "Feedstocks"].every(w => nav.some(t => t.includes(w))), "new menu items translated");
await page.evaluate(() => localStorage.setItem("lp-lang", "el"));
await page.setViewportSize({ width: 390, height: 844 });
await page.reload({ waitUntil: "load" });
await sleep(1000);
await page.evaluate(() => go("feeding"));
await sleep(800);
const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
check(overflow <= 1, `no horizontal page scroll on a phone (overflow ${overflow}px)`);
await shot("7-mobile-feeding");

check(errors.length === 0, `no JavaScript errors${errors.length ? ": " + errors.join(" | ") : ""}`);
await browser.close();
console.log(fails.length ? `\n${fails.length} CHECK(S) FAILED` : "\nALL DEMO E2E CHECKS PASSED");
process.exit(fails.length ? 1 : 0);
