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
page.on("dialog", d => d.accept());
const shot = async name => { if (SHOTS) await page.screenshot({ path: path.join(SHOTS, name + ".png") }); };
const db = (fn, ...args) => page.evaluate(fn, ...args);
const go = async view => { await page.click(`.nav-item[data-view="${view}"]`); await sleep(700); };
const openAlerts = () => db(() => window.__BIOGAS_DEMO_DB__.alerts.filter(a => !a.resolved_at));
const badge = () => page.$eval("#alert-badge", b => b.classList.contains("hidden") ? 0 : Number(b.textContent));

await page.goto(URL, { waitUntil: "load" });
await sleep(1200);

console.log("Dashboard");
const dashTiles = await page.$$eval(".stat", s => s.map(x => [x.querySelector(".k").textContent, x.querySelector(".v").textContent]));
const activeTile = dashTiles.find(t => t[0] === "Ενεργές ειδοποιήσεις");
check(activeTile && Number(activeTile[1]) === (await openAlerts()).length, `alarm tile matches open alarms (${activeTile && activeTile[1]})`);
check((await page.$$("#dash-alerts tbody tr")).length === 5, "dashboard lists the top 5 active alarms");
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

console.log("Alarms");
await go("alerts");
const before = await badge();
await page.click("[data-ack]");
await sleep(600);
check((await badge()) === before - 1, `acknowledging decrements the badge (${before} → ${await badge()})`);
await page.click('[data-af="all"]');
await sleep(500);
check(/Επιλύθηκε/.test(await page.textContent("#al-body")), "history shows resolved alarms");
check((await page.$$("#al-recips tbody tr")).length === 3, "e-mail recipients listed");
await page.click('[data-af="open"]');
await sleep(400);
await shot("6-alerts");

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
