// Route Memory acceptance tests (the 21 from the spec) + checks for Hope's decisions.
// TEST PROJECT ONLY. Real Auth, real Firestore + rules, real Cloud Functions. No emulator, no mocks.
//   GOOGLE_APPLICATION_CREDENTIALS=<service-account-or-adc json> node run.mjs
import fs from "node:fs";
import { createRequire } from "node:module";
import {
  core, adb, admin, RUN, ts, sleep, HOUR, makeUser, makeCompany, startVisit, finishVisit, waitApplied,
  completeVisit, buildHistory, getVisit, getStats, visitsOfProperty, denied, callable, Check, cleanup,
  doc, setDoc, updateDoc, getDoc, getDocs, collection, collectionGroup, query, where, orderBy, serverTimestamp, visitRef,
} from "./lib.mjs";
const require = createRequire(import.meta.url);
const fadmin = require("../functions/node_modules/firebase-admin");
fadmin.initializeApp({ projectId: "whyte-routes-test-93ee0" });
const rm = require("../functions/routeMemory.js");
const ats = (m) => admin.firestore.Timestamp.fromMillis(m);

const coA = `rmt-${RUN}-A`, coB = `rmt-${RUN}-B`, TZ = "America/Toronto";
const BASE = Date.now() - 40 * 24 * HOUR;
const results = [];
const only = process.env.ONLY ? process.env.ONLY.split(",") : null;

async function test(n, name, fn) {
  if (only && !only.includes(String(n))) return;
  const c = new Check(); const t0 = Date.now();
  try { await fn(c); results.push({ n, name, status: "PASS", notes: c.notes, secs: (Date.now() - t0) / 1000 }); }
  catch (e) { results.push({ n, name, status: "FAIL", error: e.message, notes: c.notes, secs: (Date.now() - t0) / 1000 }); }
  const r = results[results.length - 1];
  console.log(`${r.status}  ${String(n).padStart(2)}  ${name}${r.error ? "\n      " + r.error : ""}`);
}

const runDoc = (U, id, o) => setDoc(doc(U.db, "companies", U.companyId, "runs", id), {
  driverId: U.uid, driverName: U.name, routeId: "route1", routeName: "Test Route", shiftId: "shift1",
  startedAt: ts(o.startMs ?? BASE), stopCount: o.stopCount ?? 3, snowFactorActive: !!o.snow,
  snowFactor: o.snow ? core.C.SNOW_FACTOR : 1, predictedTotalSec: o.predicted ?? 0, createdAt: serverTimestamp(),
});
const stat = async (U, key) => { const s = await getDoc(doc(U.db, "companies", U.companyId, "propertyStats", key)); return s.exists() ? s.data() : null; };
// Independent recompute straight from the raw visit records.
async function expectedFromScratch(co, key) {
  const vs = (await visitsOfProperty(co, key)).filter((x) => x.v.completedAt);
  const elig = vs.filter((x) => core.isStatsEligible(x.v))
    .map((x) => ({ id: x.id, order: core.orderKey(x.v, x.id), durationSec: core.durationSecOf(x.v) }))
    .sort((a, b) => core.cmpOrder(a.order, b.order));
  const snaps = {};
  for (const e of elig) snaps[e.id] = core.snapshotFor(e.durationSec, elig.filter((p) => core.cmpOrder(p.order, e.order) < 0));
  return { elig, snaps, stats: core.statsFor(elig) };
}
async function checkConsistent(c, co, key, label) {
  const ex = await expectedFromScratch(co, key);
  const st = await getStats(co, key);
  c.eq(st.visitCount, ex.stats.visitCount, `${label}: visitCount matches recompute-from-records`);
  c.near(st.avgDurationSec, ex.stats.avgDurationSec, `${label}: last-5 average matches recompute-from-records`);
  for (const e of ex.elig) {
    const v = await getVisit(co, e.id);
    c.near(v.durationSec, ex.snaps[e.id].durationSec, `${label}: ${e.id} durationSec`);
    c.eq(v.visitCountBefore, ex.snaps[e.id].visitCountBefore, `${label}: ${e.id} visitCountBefore`);
    c.eq(v.flagged, ex.snaps[e.id].flagged, `${label}: ${e.id} flagged`);
    if (ex.snaps[e.id].avgBeforeSec != null) c.near(v.avgBeforeSec, ex.snaps[e.id].avgBeforeSec, `${label}: ${e.id} avgBeforeSec`);
  }
}

const users = [];
let ownerA, managerA, dA1, dA2, ownerB, dB;
console.log(`Route Memory acceptance run ${RUN} on whyte-routes-test-93ee0\n`);
await makeCompany(coA, "RM Test Co A", TZ); await makeCompany(coB, "RM Test Co B", TZ);
ownerA = await makeUser("ownerA", coA, "owner"); managerA = await makeUser("managerA", coA, "manager");
dA1 = await makeUser("driverA1", coA, "driver"); dA2 = await makeUser("driverA2", coA, "driver");
ownerB = await makeUser("ownerB", coB, "owner"); dB = await makeUser("driverB", coB, "driver");
users.push(ownerA, managerA, dA1, dA2, ownerB, dB);

// ── 1 ──────────────────────────────────────────────────────────
await test(1, "3 visits (6, 8, 10 min) -> predicts 8 min, 'avg of last 3 visits'", async (c) => {
  await buildHistory(dA1, { stop: "p1-stop", customer: "p1" }, [360, 480, 600], BASE);
  const s = await stat(dA1, "p1");                       // read as the driver, like the phone does
  const p = core.predict(s, "double", false);
  c.eq(s.visitCount, 3, "visitCount"); c.eq(p.sec, 480, "predicted seconds (8 min)"); c.eq(p.basis, "avg of last 3 visits", "basis label");
});
// ── 2 ──────────────────────────────────────────────────────────
await test(2, "new property, sizeTier double -> 9 min, 'estimate'", async (c) => {
  const s = await stat(dA1, "brand-new-prop"); c.eq(s, null, "no stats exist yet");
  const p = core.predict(s, "double", false); c.eq(p.sec, 540, "predicted seconds (9 min)"); c.eq(p.basis, "estimate", "basis label");
});
// ── 3 ──────────────────────────────────────────────────────────
await test(3, "run summary: total = sum, finish = start + total, 'service time only', heavy snow +30%", async (c) => {
  await buildHistory(dA1, { stop: "p3b-stop", customer: "p3b" }, [300, 500], BASE);
  const stops = [["p1", "double"], ["p3b", "single"], ["n-single", "single"], ["n-triple", "triple"], ["n-unk", null]];
  const preds = []; for (const [k, tier] of stops) preds.push(core.predict(await stat(dA1, k), tier, false));
  const total = preds.reduce((a, p) => a + p.sec, 0);
  c.eq(total, 480 + 400 + 360 + 720 + 540, "total = sum of the five predictions");
  c.eq(preds[1].basis, "avg of last 2 visits", "2-visit property labelled with 2");
  const startMs = Date.now();
  const sm = core.runSummary({ stopCount: 5, totalServiceSec: total, startMs, tz: TZ });
  c.eq(sm.finishMs, startMs + total * 1000, "finish = start + total");
  c.ok(/service time only/.test(sm.text), `summary says "service time only": ${sm.text}`);
  const snowTotal = (await Promise.all(stops.map(async ([k, t]) => core.predict(await stat(dA1, k), t, true).sec))).reduce((a, b) => a + b, 0);
  c.near(snowTotal, total * 1.3, "heavy snow ON -> total grows 30%");
  await runDoc(dA1, `r3-${RUN}`, { stopCount: 5, snow: true, predicted: snowTotal, startMs });
  const r = (await getDoc(doc(dA1.db, "companies", coA, "runs", `r3-${RUN}`))).data();
  c.eq(r.snowFactorActive, true, "run stores snowFactorActive"); c.eq(r.snowFactor, 1.3, "run stores the factor used");
});
// ── 4 ──────────────────────────────────────────────────────────
const R4 = `r4-${RUN}`; let r4visits = [];
await test(4, "finished run appears in Shift History with correct counts, total and per-stop detail", async (c) => {
  await runDoc(dA1, R4, { startMs: BASE + 100 * HOUR, stopCount: 3 });
  const t = BASE + 100 * HOUR;
  for (const [i, d] of [[0, 600], [1, 420]]) r4visits.push((await completeVisit(dA1, { stopId: `r4s${i}`, customerId: `r4c${i}`, arrivedMs: t + i * 1800e3, durationSec: d, runId: R4, address: `${i + 1} Run Four Rd` })).id);
  const skipId = await startVisit(dA1, { stopId: "r4s2", customerId: "r4c2", arrivedMs: t + 3600e3, runId: R4, address: "3 Run Four Rd" });
  await updateDoc(visitRef(dA1.db, coA, skipId), { skippedAt: ts(t + 3700e3), outcome: "skipped" }); r4visits.push(skipId);
  await updateDoc(doc(dA1.db, "companies", coA, "runs", R4), { endedAt: ts(t + 2 * HOUR) });
  for (const U of [dA1, ownerA, managerA]) {
    const vs = (await getDocs(query(collection(U.db, "companies", coA, "serviceHistory"), where("runId", "==", R4), ...(U.role === "driver" ? [where("driverId", "==", U.uid)] : []), orderBy("arrivedAt")))).docs.map((d) => d.data());
    c.eq(vs.length, 3, `${U.label} sees the run's 3 stops`);
    const run = (await getDoc(doc(U.db, "companies", coA, "runs", R4))).data();
    const row = core.runRow(run, vs, Date.now());
    c.eq(row.stopsCompleted, 2, `${U.label}: stops completed`); c.eq(row.stopsSkipped, 1, `${U.label}: stops skipped`);
    c.eq(row.totalTimeSec, 7200, `${U.label}: total time on route`); c.eq(row.avgPerStopSec, 3600, `${U.label}: average per stop`);
  }
  const det = await getVisit(coA, r4visits[0]);
  c.eq(det.arrivedAt.toMillis(), t, "stop 1 real start"); c.eq(det.completedAt.toMillis(), t + 600e3, "stop 1 real complete"); c.eq(det.durationSec, 600, "stop 1 duration");
  c.ok(await denied(getDoc(doc(dA2.db, "companies", coA, "runs", R4))), "another driver can't read this driver's run");
});
// ── 5 ──────────────────────────────────────────────────────────
await test(5, "CSV export: one row per stop with the same figures", async (c) => {
  const rows = []; for (const id of r4visits) rows.push({ id, visit: await getVisit(coA, id) });
  const csv = core.buildRunCsv(rows, TZ, Date.now());
  const lines = csv.trim().split("\n"); c.eq(lines.length, 4, "header + 3 rows");
  c.eq(lines[0], "Address,Driver,Start,Complete,Duration,Status,Flagged,Reason", "columns incl. Flagged, Reason");
  const t = BASE + 100 * HOUR;
  c.eq(lines[1], `1 Run Four Rd,driverA1,${core.formatLocalDateTime(t, TZ)},${core.formatLocalDateTime(t + 600e3, TZ)},10:00,completed,No,`, "row 1 figures");
  c.eq(lines[2], `2 Run Four Rd,driverA1,${core.formatLocalDateTime(t + 1800e3, TZ)},${core.formatLocalDateTime(t + 2220e3, TZ)},7:00,completed,No,`, "row 2 figures");
  c.ok(/^3 Run Four Rd,driverA1,.*,,,skipped,No,$/.test(lines[3]), `row 3 is the skipped stop: ${lines[3]}`);
});
// ── 6 ──────────────────────────────────────────────────────────
await test(6, "Company B never sees Company A (stats, history, predictions) - incl. hand-crafted queries", async (c) => {
  await buildHistory(dA1, { stop: "shared-a", customer: "shared-key" }, [300, 300, 300], BASE);
  await buildHistory(dB, { stop: "shared-b", customer: "shared-key" }, [600, 600, 600], BASE);
  const a = await stat(dA1, "shared-key"), b = await stat(dB, "shared-key");
  c.eq(a.avgDurationSec, 300, "A's average from A's data only"); c.eq(b.avgDurationSec, 600, "B's average from B's data only");
  for (const [who, U] of [["owner B", ownerB], ["driver B", dB]]) {
    c.ok(await denied(getDocs(collection(U.db, "companies", coA, "serviceHistory"))), `${who}: list A's visits denied`);
    c.ok(await denied(getDoc(doc(U.db, "companies", coA, "propertyStats", "shared-key"))), `${who}: read A's stats denied`);
    c.ok(await denied(getDocs(collection(U.db, "companies", coA, "runs"))), `${who}: list A's runs denied`);
    c.ok(await denied(getDocs(query(collectionGroup(U.db, "serviceHistory"), where("propertyKey", "==", "shared-key")))), `${who}: cross-company collectionGroup query denied`);
    c.ok(await denied(setDoc(visitRef(U.db, coA, "evil"), { stopId: "x", routeId: "y", outcome: "in_progress", source: "app", driverId: U.uid })), `${who}: write into A denied`);
    c.ok(await denied(setDoc(doc(U.db, "companies", coA, "propertyStats", "shared-key"), { avgDurationSec: 1 })), `${who}: writing A's stats denied`);
  }
});
// ── 7, 8, 13 (same property) ───────────────────────────────────
const R7 = `r7-${RUN}`; let v7;
await test(7, "avg 5 min, complete at 10 min -> flagged, '2.00x usual' in run detail and visit history", async (c) => {
  await runDoc(dA1, R7, { startMs: BASE + 200 * HOUR });
  await buildHistory(dA1, { stop: "p7-stop", customer: "p7" }, [300, 300, 300], BASE + 150 * HOUR);
  v7 = await completeVisit(dA1, { stopId: "p7-stop", customerId: "p7", arrivedMs: BASE + 200 * HOUR, durationSec: 600, runId: R7 });
  c.eq(v7.data.flagged, true, "flagged"); c.near(v7.data.flagRatio, 2, "stored ratio"); c.eq(v7.data.avgBeforeSec, 300, "avgBefore"); c.eq(v7.data.visitCountBefore, 3, "visitCountBefore");
  const inRun = (await getDocs(query(collection(ownerA.db, "companies", coA, "serviceHistory"), where("runId", "==", R7)))).docs.map((d) => d.data());
  const inHist = (await getDocs(query(collection(ownerA.db, "companies", coA, "serviceHistory"), where("propertyKey", "==", "p7"), orderBy("completedAt", "desc")))).docs.map((d) => d.data());
  c.eq(core.formatFlagTag(inRun[0].flagRatio), "2.00x usual", "tag in run detail");
  c.eq(core.formatFlagTag(inHist[0].flagRatio), "2.00x usual", "tag in visit history");
});
await test(8, "same property, complete at 6 min -> NOT flagged", async (c) => {
  const v = await completeVisit(dA1, { stopId: "p7-stop", customerId: "p7", arrivedMs: BASE + 201 * HOUR, durationSec: 360 });
  c.eq(v.data.flagged, false, "not flagged"); c.eq(v.data.avgBeforeSec, 375, "avgBefore (300,300,300,600)");
});
await test(9, "avg 3 min, complete at 5 min (overrun exactly 120 s) -> NOT flagged", async (c) => {
  await buildHistory(dA1, { stop: "p9-stop", customer: "p9" }, [180, 180, 180], BASE);
  const v = await completeVisit(dA1, { stopId: "p9-stop", customerId: "p9", arrivedMs: BASE + 10 * HOUR, durationSec: 300 });
  c.near(v.data.flagRatio, 300 / 180, "ratio is 1.67 (over the ratio rule)"); c.eq(v.data.flagged, false, "not flagged: 120 s is not MORE than 120 s");
});
// ── 10 ─────────────────────────────────────────────────────────
await test(10, "reason chip saved + shown with the flag and in CSV; Complete never blocked by chips", async (c) => {
  await buildHistory(dA1, { stop: "p10-stop", customer: "p10" }, [300, 300, 300], BASE);
  const id = await startVisit(dA1, { stopId: "p10-stop", customerId: "p10", arrivedMs: BASE + 20 * HOUR });
  await updateDoc(visitRef(dA1.db, coA, id), { reasonCode: "deep_snow" });     // tapped while over-running
  await finishVisit(dA1, id, BASE + 20 * HOUR + 700e3);
  const v = await waitApplied(coA, id);
  c.eq(v.flagged, true, "visit flagged"); c.eq(v.reasonCode, "deep_snow", "reason saved with the visit");
  const csv = core.buildRunCsv([{ id, visit: v }], TZ, Date.now()).trim().split("\n")[1];
  c.ok(csv.endsWith(",Yes,Deep snow"), `CSV shows Flagged=Yes, Reason=Deep snow: ${csv}`);
  const n = await completeVisit(dA1, { stopId: "p10-stop", customerId: "p10", arrivedMs: BASE + 21 * HOUR, durationSec: 300 });
  c.eq(n.data.reasonCode, undefined, "completed with NO chip: reason empty"); c.ok(!!n.data.statsAppliedAt, "visit still completed");
  const o = await startVisit(dA1, { stopId: "p10-stop", customerId: "p10", arrivedMs: BASE + 22 * HOUR });
  await updateDoc(visitRef(dA1.db, coA, o), { reasonCode: "other", reasonText: "x".repeat(80) }); c.ok(true, "'Other' + 80-char text accepted");
  c.ok(await denied(updateDoc(visitRef(dA1.db, coA, o), { reasonText: "y".repeat(81) })), "81 chars refused");
  c.ok(await denied(updateDoc(visitRef(dA1.db, coA, o), { reasonCode: "bogus" })), "unknown chip refused");
  c.ok(await denied(updateDoc(visitRef(dA1.db, coA, o), { reasonCode: "deep_snow", reasonText: "no" })), "free text only allowed with 'Other'");
  c.ok(await denied(updateDoc(visitRef(dA1.db, coA, id), { reasonCode: "other", reasonText: "late" })), "reason can't change after the snapshot");
});
// ── 11, 12 ─────────────────────────────────────────────────────
await test(11, "BOUNDARY avg 4 min, complete at exactly 6:00 -> NOT flagged", async (c) => {
  await buildHistory(dA1, { stop: "p11-stop", customer: "p11" }, [240, 240, 240], BASE);
  const v = await completeVisit(dA1, { stopId: "p11-stop", customerId: "p11", arrivedMs: BASE + 10 * HOUR, durationSec: 360 });
  c.near(v.data.flagRatio, 1.5, "ratio exactly 1.5"); c.eq(v.data.flagged, false, "not flagged (overrun exactly 120 s)");
});
await test(12, "BOUNDARY avg 4 min, complete at 6:01 -> flagged", async (c) => {
  // A fresh property with the same 4-minute history: test 11's 6:00 visit already moved p11's average.
  await buildHistory(dA1, { stop: "p12-stop", customer: "p12" }, [240, 240, 240], BASE);
  const v = await completeVisit(dA1, { stopId: "p12-stop", customerId: "p12", arrivedMs: BASE + 10 * HOUR, durationSec: 361 });
  c.eq(v.data.flagged, true, "flagged (overrun 121 s, ratio >= 1.5)"); c.eq(core.formatFlagTag(v.data.flagRatio), "1.50x usual", "tag");
});
await test(13, "SNAPSHOT: later visits change the average, old flag + '2.00x usual' unchanged", async (c) => {
  const before = await getVisit(coA, v7.id);
  await buildHistory(dA1, { stop: "p7-stop", customer: "p7" }, [900, 900, 900], BASE + 300 * HOUR);
  const after = await getVisit(coA, v7.id), s = await getStats(coA, "p7");
  c.near(s.avgDurationSec, 732, "property average moved a lot (600,360,900,900,900)");
  for (const k of ["flagged", "flagRatio", "avgBeforeSec", "visitCountBefore", "durationSec"]) c.eq(after[k], before[k], `old visit ${k} unchanged`);
  c.eq(core.formatFlagTag(after.flagRatio), "2.00x usual", "tag unchanged");
});
// ── 14 ─────────────────────────────────────────────────────────
await test(14, "IDEMPOTENCY: same completion twice / retried -> stats apply once", async (c) => {
  await buildHistory(dA1, { stop: "p14-stop", customer: "p14" }, [300, 300, 300], BASE);
  const a = await startVisit(dA1, { stopId: "p14-stop", customerId: "p14", arrivedMs: BASE + 10 * HOUR });
  await Promise.all([finishVisit(dA1, a, BASE + 10 * HOUR + 300e3), finishVisit(dA1, a, BASE + 10 * HOUR + 300e3)]);   // double-tap
  const first = await waitApplied(coA, a);
  await finishVisit(dA1, a, BASE + 10 * HOUR + 300e3);                                                              // re-sync
  const results = await Promise.all([1, 2, 3, 4].map(() => rm._internal.applyCompletion(coA, a)));                  // retried deliveries
  c.ok(results.every((r) => r === "already-applied"), `every retry is a no-op: ${results.join(",")}`);
  await adb.collection("companies").doc(coA).collection("serviceHistory").doc(a).update({ address: "touched by admin" });   // unrelated write fires the trigger again
  await sleep(10000);
  const later = await getVisit(coA, a);
  c.eq(later.statsAppliedAt.toMillis(), first.statsAppliedAt.toMillis(), "snapshot written once");
  c.eq((await getStats(coA, "p14")).visitCount, 4, "visit counted exactly once (3 + 1)");
  await checkConsistent(c, coA, "p14", "p14");
});
// ── 15 ─────────────────────────────────────────────────────────
await test(15, "ELIGIBILITY: skipped + incomplete (+ recovered-from-logs) never touch average, prediction or flags", async (c) => {
  await buildHistory(dA1, { stop: "p15-stop", customer: "p15" }, [300, 300, 300], BASE);
  const s0 = await getStats(coA, "p15");
  const sk = await startVisit(dA1, { stopId: "p15-stop", customerId: "p15", arrivedMs: BASE + 10 * HOUR });
  await updateDoc(visitRef(dA1.db, coA, sk), { skippedAt: ts(BASE + 10 * HOUR + 60e3), outcome: "skipped" });
  const inc = await startVisit(dA1, { stopId: "p15-stop", customerId: "p15", arrivedMs: Date.now() - 20 * HOUR });   // never finished, >18h old
  await adb.collection("companies").doc(coA).collection("serviceHistory").doc("p15-recovered").set({
    stopId: "p15-stop", routeId: "route1", propertyKey: "p15", outcome: "completed", source: "recovered_from_logs",
    arrivedAt: ats(BASE + 11 * HOUR), completedAt: ats(BASE + 11 * HOUR + 3000e3), driverId: dA1.uid, address: "x" });
  await sleep(12000);
  const s1 = await getStats(coA, "p15");
  c.eq(s1.visitCount, s0.visitCount, "visitCount unchanged"); c.eq(s1.avgDurationSec, s0.avgDurationSec, "average unchanged");
  c.eq(core.predict(s1, null, false).sec, core.predict(s0, null, false).sec, "prediction unchanged");
  const skv = await getVisit(coA, sk), icv = await getVisit(coA, inc);
  c.ok(skv.flagged === undefined && skv.flagRatio === undefined, "skipped visit has no flag"); c.ok(icv.flagged === undefined, "incomplete visit has no flag");
  c.eq(core.effectiveStatus(icv, Date.now()), "incomplete", "stale open visit reads as 'incomplete'");
  const n = await completeVisit(dA1, { stopId: "p15-stop", customerId: "p15", arrivedMs: BASE + 12 * HOUR, durationSec: 330 });
  c.eq(n.data.avgBeforeSec, 300, "next visit's average ignores all three"); c.eq(n.data.visitCountBefore, 3, "and counts only the 3 real ones");
});
// ── 16 ─────────────────────────────────────────────────────────
await test(16, "DST: visit across 14 Mar 2027 spring-forward (America/Toronto), UTC storage, no 1-hour drift", async (c) => {
  const a = Date.UTC(2027, 2, 14, 6, 50), e = Date.UTC(2027, 2, 14, 7, 10);          // 1:50 AM EST -> 3:10 AM EDT
  const v = await completeVisit(dA1, { stopId: "p16-stop", customerId: "p16", arrivedMs: a, durationSec: (e - a) / 1000 });
  c.eq(v.data.durationSec, 1200, "durationSec = true elapsed 20 min (not 80)");
  const raw = await getVisit(coA, v.id);
  c.eq(raw.arrivedAt.toMillis(), a, "stored start is the exact UTC instant"); c.eq(raw.completedAt.toMillis(), e, "stored end is the exact UTC instant");
  c.eq(core.formatLocalDateTime(a, TZ), "2027-03-14 01:50", "displayed start (local)"); c.eq(core.formatLocalDateTime(e, TZ), "2027-03-14 03:10", "displayed end (local)");
  const sm = core.runSummary({ stopCount: 1, totalServiceSec: 7200, startMs: Date.UTC(2027, 2, 14, 6, 30), tz: TZ });
  c.eq(sm.finishMs, Date.UTC(2027, 2, 14, 8, 30), "predicted finish is the true instant (2 h after start)");
  c.ok(sm.text.includes("4:30 AM"), `finish shows 4:30 AM local (a naive wall-clock add would say 3:30): ${sm.text}`);
});
// ── 17 ─────────────────────────────────────────────────────────
await test(17, "CONCURRENCY: two drivers complete at the same property at once (x3 rounds) - both counted once, stats consistent", async (c) => {
  await buildHistory(dA1, { stop: "p17-stop", customer: "p17" }, [300, 300, 300], BASE);
  for (let round = 0; round < 3; round++) {
    const t = BASE + (20 + round * 3) * HOUR;
    const [i1, i2] = await Promise.all([startVisit(dA1, { stopId: "p17-stop", customerId: "p17", arrivedMs: t }), startVisit(dA2, { stopId: "p17-stop", customerId: "p17", arrivedMs: t + 60e3 })]);
    await Promise.all([finishVisit(dA1, i1, t + 300e3), finishVisit(dA2, i2, t + 60e3 + 420e3)]);
    await Promise.all([waitApplied(coA, i1), waitApplied(coA, i2)]);
    await checkConsistent(c, coA, "p17", `round ${round + 1}`);
  }
  c.eq((await getStats(coA, "p17")).visitCount, 9, "3 history + 6 concurrent = 9, none lost, none doubled");
  const raceTarget = (await visitsOfProperty(coA, "p17"))[0].id;
  const rs = await Promise.all([1, 2, 3, 4, 5, 6].map(() => rm._internal.applyCompletion(coA, raceTarget)));
  c.ok(rs.every((r) => r === "already-applied"), "six simultaneous re-applies are all no-ops");
});
// ── 18 ─────────────────────────────────────────────────────────
await test(18, "SNOW ISOLATION: Heavy snow run stores snowFactorActive; stats hold only real durations", async (c) => {
  const R = `r18-${RUN}`; await runDoc(dA1, R, { snow: true, startMs: BASE + 400 * HOUR });
  await completeVisit(dA1, { stopId: "p18-stop", customerId: "p18", arrivedMs: BASE + 400 * HOUR, durationSec: 300, runId: R });
  await completeVisit(dA1, { stopId: "p18-stop", customerId: "p18", arrivedMs: BASE + 401 * HOUR, durationSec: 500, runId: R });
  const run = (await getDoc(doc(dA1.db, "companies", coA, "runs", R))).data();
  c.eq(run.snowFactorActive, true, "run.snowFactorActive"); c.eq(run.snowFactor, 1.3, "run.snowFactor");
  const s = await getStats(coA, "p18");
  c.eq(s.avgDurationSec, 400, "stored average = real durations only (not 520)");
  c.near(core.predict(s, null, true).sec, 520, "the snow prediction is 1.3x, and exists only in that run's prediction");
  c.eq((await getStats(coA, "p18")).avgDurationSec, 400, "stored stats still 400 afterwards");
});
// ── 19 ─────────────────────────────────────────────────────────
await test(19, "SCALE: 200 historical visits recompute without limit errors; last-5 average correct", async (c) => {
  const durs = []; let batch = adb.batch(); 
  for (let i = 0; i < 200; i++) {
    const d = 120 + ((i * 37) % 400); durs.push(d);
    const a = BASE + i * 2 * HOUR;
    batch.set(adb.collection("companies").doc(coA).collection("serviceHistory").doc(`scale-${String(i).padStart(3, "0")}`), {
      stopId: "scale-stop", routeId: "route1", propertyKey: "scale", outcome: "completed", source: "app", address: "Scale St",
      driverId: dA1.uid, arrivedAt: ats(a), completedAt: ats(a + d * 1000), statsAppliedAt: ats(Date.now()), preRouteMemory: true });
    if (i % 100 === 99) { await batch.commit(); batch = adb.batch(); }
  }
  const r = await callable(ownerA, "recomputePropertyStats", { propertyKey: "scale" });
  c.ok(r.ok, `recompute completed: ${JSON.stringify(r.ok ? r.data : r)}`);
  const s = await getStats(coA, "scale");
  c.eq(s.visitCount, 200, "visitCount"); c.near(s.avgDurationSec, durs.slice(-5).reduce((a, b) => a + b, 0) / 5, "last-5 average");
  c.eq(s.lastDurationSec, durs[199], "last duration");
});
// ── 20 ─────────────────────────────────────────────────────────
await test(20, "BASIS LABEL: 20 completed visits -> average of the 5 most recent, 'avg of last 5 visits'", async (c) => {
  const durs = Array.from({ length: 20 }, (_, i) => 200 + i * 25);
  await buildHistory(dA1, { stop: "p20-stop", customer: "p20" }, durs, BASE);
  const s = await stat(dA1, "p20"); const p = core.predict(s, null, false);
  c.eq(s.visitCount, 20, "20 visits counted"); c.near(p.sec, durs.slice(-5).reduce((a, b) => a + b, 0) / 5, "prediction = average of the 5 most recent");
  c.eq(p.basis, "avg of last 5 visits", "label says 5, never 20");
});
// ── 21 ─────────────────────────────────────────────────────────
await test(21, "OWNER CORRECTION: recalculates that visit + property, others untouched, audit record, driver denied", async (c) => {
  const h = await buildHistory(dA1, { stop: "p21-stop", customer: "p21" }, [300, 300, 300], BASE);
  const V = await completeVisit(dA1, { stopId: "p21-stop", customerId: "p21", arrivedMs: BASE + 10 * HOUR, durationSec: 600 });
  const L = await completeVisit(dA1, { stopId: "p21-stop", customerId: "p21", arrivedMs: BASE + 11 * HOUR, durationSec: 330 });
  c.eq(V.data.flagged, true, "starts flagged");
  const others = [...h.map((x) => x.id), L.id], snapBefore = {};
  const KEYS = ["durationSec", "avgBeforeSec", "visitCountBefore", "flagRatio", "flagged", "arrivedAt", "completedAt"];
  for (const id of others) { const v = await getVisit(coA, id); snapBefore[id] = Object.fromEntries(KEYS.map((k) => [k, v[k]?.toMillis?.() ?? v[k]])); }
  const origCompleted = (await getVisit(coA, V.id)).completedAt.toMillis();

  // denied: driver, manager (callable) + direct writes by anyone
  for (const [who, U] of [["driver", dA1], ["manager", managerA]]) {
    const r = await callable(U, "correctVisit", { visitId: V.id, correctedCompletedAtMs: BASE + 10 * HOUR + 400e3 });
    c.ok(!r.ok && /permission-denied/.test(r.code), `${who} calling correctVisit is denied`);
  }
  for (const [who, U] of [["driver", dA1], ["manager", managerA], ["owner (directly)", ownerA]]) {
    c.ok(await denied(updateDoc(visitRef(U.db, coA, V.id), { correctedCompletedAt: ts(BASE + 10 * HOUR + 400e3) })), `${who} writing correctedCompletedAt straight to the record is denied`);
    c.ok(await denied(updateDoc(visitRef(U.db, coA, V.id), { durationSec: 1 })), `${who} writing durationSec is denied`);
  }
  c.eq((await getVisit(coA, V.id)).durationSec, 600, "nothing changed after the denied attempts");
  const bad = await callable(ownerA, "correctVisit", { visitId: V.id, correctedCompletedAtMs: BASE + 10 * HOUR - 1000 });
  c.ok(!bad.ok && /invalid-argument/.test(bad.code), "end before start is rejected");

  // the real correction: 10:00 -> 6:40
  const r = await callable(ownerA, "correctVisit", { visitId: V.id, correctedCompletedAtMs: BASE + 10 * HOUR + 400e3, note: "driver forgot to tap Done" });
  c.ok(r.ok, `owner correction accepted: ${JSON.stringify(r.ok ? r.data : r)}`);
  const v = await getVisit(coA, V.id);
  c.eq(v.durationSec, 400, "durationSec recalculated"); c.eq(v.avgBeforeSec, 300, "avgBeforeSec recalculated from the record set");
  c.eq(v.visitCountBefore, 3, "visitCountBefore"); c.near(v.flagRatio, 400 / 300, "flagRatio recalculated"); c.eq(v.flagged, false, "flag recalculated (100 s over: no longer flagged)");
  c.eq(v.completedAt.toMillis(), origCompleted, "ORIGINAL completedAt untouched"); c.eq(v.correctedCompletedAt.toMillis(), BASE + 10 * HOUR + 400e3, "correction stored as an overlay");
  const s = await getStats(coA, "p21"); c.eq(s.visitCount, 5, "property visitCount"); c.near(s.avgDurationSec, (300 + 300 + 300 + 400 + 330) / 5, "property stats recomputed with the corrected 400");
  for (const id of others) { const x = await getVisit(coA, id); for (const k of KEYS) c.eq(x[k]?.toMillis?.() ?? x[k], snapBefore[id][k], `other visit ${id.slice(-8)} ${k} unchanged`); }
  const aud = (await adb.collection("companies").doc(coA).collection("serviceHistory").doc(V.id).collection("corrections").get()).docs.map((d) => d.data());
  c.eq(aud.length, 1, "one audit record"); const a = aud[0];
  c.eq(a.original.durationSec, 600, "audit: original values"); c.eq(a.corrected.durationSec, 400, "audit: corrected values");
  c.eq(a.editorUid, ownerA.uid, "audit: editor identity"); c.ok(!!a.correctedAt, "audit: timestamp");
  const cs = await getDocs(collection(ownerA.db, "companies", coA, "serviceHistory", V.id, "corrections")); c.eq(cs.size, 1, "owner can read the audit trail");
  c.ok(await denied(getDocs(collection(managerA.db, "companies", coA, "serviceHistory", V.id, "corrections"))), "manager can't read the audit trail");
  c.ok(await denied(getDocs(collection(dA1.db, "companies", coA, "serviceHistory", V.id, "corrections"))), "driver can't read the audit trail");
  // status correction: "this wasn't really completed" -> leaves the stats
  const r2 = await callable(ownerA, "correctVisit", { visitId: L.id, correctedOutcome: "skipped" });
  c.ok(r2.ok, "owner status correction accepted"); c.eq((await getStats(coA, "p21")).visitCount, 4, "corrected-away visit no longer counts");
  const r3 = await callable(ownerA, "correctVisit", { visitId: "p21-nonexistent", correctedOutcome: "skipped" }); c.ok(!r3.ok, "unknown visit rejected");
});
// ── decisions ──────────────────────────────────────────────────
await test("D10", "Decision 10: managers read ALL shift history + runs (read-only); drivers only their own", async (c) => {
  await adb.collection("companies").doc(coA).collection("drivers").doc(dA1.uid).collection("shifts").doc("s1").set({ driverId: dA1.uid, startedAt: ats(BASE), status: "completed" });
  c.ok(!(await denied(getDoc(doc(managerA.db, "companies", coA, "drivers", dA1.uid, "shifts", "s1")))), "manager reads a driver's shift");
  c.ok(!(await denied(getDoc(doc(ownerA.db, "companies", coA, "drivers", dA1.uid, "shifts", "s1")))), "owner reads a driver's shift");
  c.ok(await denied(getDoc(doc(dA2.db, "companies", coA, "drivers", dA1.uid, "shifts", "s1"))), "another driver can't");
  c.ok(await denied(setDoc(doc(managerA.db, "companies", coA, "drivers", dA1.uid, "shifts", "s2"), { driverId: dA1.uid, startedAt: ts(BASE), status: "active" })), "manager can't write a driver's shift");
  c.ok(!(await denied(getDoc(doc(managerA.db, "companies", coA, "runs", R4)))), "manager reads another driver's run");
  c.ok(await denied(updateDoc(doc(managerA.db, "companies", coA, "runs", R4), { snowFactorActive: true })), "manager can't edit a run");
});
await test("D9", "Decision 9: recovered_from_logs + owner-ticked (no arrival) visits are excluded from stats", async (c) => {
  c.eq(core.isStatsEligible({ outcome: "completed", source: "recovered_from_logs", arrivedAt: ts(1000), completedAt: ts(5000) }), false, "recovered_from_logs excluded");
  c.eq(core.isStatsEligible({ outcome: "completed", source: "app", completedAt: ts(5000) }), false, "no arrival time -> no duration -> excluded");
  c.eq(core.isStatsEligible({ outcome: "completed", source: "app", arrivedAt: ts(1000), completedAt: ts(5000) }), true, "real recorded times count");
});

// ── report ────────────────────────────────────────────────────
fs.mkdirSync("results", { recursive: true });
fs.writeFileSync("results/results.json", JSON.stringify({ run: RUN, project: "whyte-routes-test-93ee0", at: new Date().toISOString(), results }, null, 2));
const pass = results.filter((r) => r.status === "PASS").length;
const md = [`# Route Memory acceptance results\n`, `Run ${RUN} on whyte-routes-test-93ee0 - ${new Date().toISOString()}\n`, `**${pass} PASS / ${results.length - pass} FAIL**\n`,
  ...results.map((r) => `- **${r.status}** ${r.n}. ${r.name}${r.error ? `\n  - ${r.error}` : ""}`)].join("\n");
fs.writeFileSync("results/RESULTS.md", md);
console.log(`\n${pass}/${results.length} passed`);
if (!process.env.KEEP) await cleanup([coA, coB], users);
process.exit(results.some((r) => r.status === "FAIL") ? 1 : 0);
