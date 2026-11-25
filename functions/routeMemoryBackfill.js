// Route Memory - one-time backfill for visits recorded before the feature.
//
//   node routeMemoryBackfill.js --project <id> [--company <id>] [--apply]
//
// DRY RUN by default: reads, prints counts, writes nothing. --apply writes.
// PRODUCTION (whyte-routes) is refused unless --i-have-hopes-approval-for-production
// is also passed - and that flag is Hope's decision, not the script's.
//
// What it does, per company, for every serviceHistory visit:
//   1. adds propertyKey (customerId, else stopId) where missing;
//   2. for completed visits the server never processed, sets the
//      "statsAppliedAt" marker + preRouteMemory:true (and durationSec when
//      the visit has real arrival + completion times) so the live trigger
//      leaves them ALONE: old visits stay unflagged ("before Route Memory")
//      rather than getting invented past flags;
//   3. rebuilds propertyStats for each property from the visits that
//      count (completed, real recorded times, not recovered_from_logs).
// Visits that already have statsAppliedAt are never touched. Safe to re-run.
//
// The decision logic (planVisit / buildStatsFromVisits) is pure and tested
// without a database: route-memory-tests/backfill.test.mjs.

const core = require("./routeMemoryCore");

const PRODUCTION_PROJECT = "whyte-routes";

// What to change on one visit document. Returns null when nothing to do.
// `markerValue` is the value for statsAppliedAt (a server timestamp at run time).
function planVisit(v, markerValue) {
  const patch = {};
  const key = v.propertyKey || v.customerId || v.stopId;
  if (!v.propertyKey && key) patch.propertyKey = key;
  if (v.outcome === "completed" && v.completedAt && !v.statsAppliedAt) {
    patch.statsAppliedAt = markerValue;
    patch.preRouteMemory = true;
    const d = core.durationSecOf(v);
    if (d != null && v.source !== "recovered_from_logs") patch.durationSec = d;
  }
  return Object.keys(patch).length ? patch : null;
}

// propertyStats documents from a list of { id, data } visits.
// Returns { [propertyKey]: { visitCount, avgDurationSec, lastDurationSec, lastVisitId } }.
function buildStatsFromVisits(visits) {
  const byKey = {};
  for (const { id, data: v } of visits) {
    const key = v.propertyKey || v.customerId || v.stopId;
    if (!key || !v.completedAt || !core.isStatsEligible(v)) continue;
    (byKey[key] = byKey[key] || []).push({ id, order: core.orderKey(v, id), durationSec: core.durationSecOf(v) });
  }
  const out = {};
  for (const [key, list] of Object.entries(byKey)) {
    list.sort((a, b) => core.cmpOrder(a.order, b.order));
    out[key] = { ...core.statsFor(list), lastVisitId: list[list.length - 1].id };
  }
  return out;
}

module.exports = { planVisit, buildStatsFromVisits, PRODUCTION_PROJECT };

// ── runner ───────────────────────────────────────────────────────
if (require.main === module) {
  const args = process.argv.slice(2);
  const opt = (n) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i + 1] : null; };
  const project = opt("project"), onlyCompany = opt("company"), apply = args.includes("--apply");
  if (!project) { console.error("Usage: node routeMemoryBackfill.js --project <id> [--company <id>] [--apply]"); process.exit(2); }
  if (project === PRODUCTION_PROJECT && !args.includes("--i-have-hopes-approval-for-production")) {
    console.error(`Refusing: ${PRODUCTION_PROJECT} is PRODUCTION. This needs Hope's explicit go-ahead (and a passing run on the test project first).`);
    process.exit(3);
  }
  const admin = require("firebase-admin");
  admin.initializeApp({ projectId: project });
  const db = admin.firestore();
  const FieldValue = admin.firestore.FieldValue;

  (async () => {
    console.log(`${apply ? "APPLY" : "DRY RUN"} on project ${project}${onlyCompany ? `, company ${onlyCompany}` : ""}`);
    const companies = onlyCompany
      ? [db.collection("companies").doc(onlyCompany)]
      : (await db.collection("companies").listDocuments());
    const total = { companies: 0, visits: 0, keyAdded: 0, markerAdded: 0, durationAdded: 0, statsDocs: 0 };
    for (const co of companies) {
      const visits = [];
      let last = null;
      for (;;) {
        let q = co.collection("serviceHistory").orderBy(admin.firestore.FieldPath.documentId()).limit(500);
        if (last) q = q.startAfter(last);
        const snap = await q.get();
        snap.docs.forEach((d) => visits.push({ id: d.id, ref: d.ref, data: d.data() }));
        if (snap.size < 500) break;
        last = snap.docs[snap.docs.length - 1];
      }
      if (!visits.length) continue;
      total.companies++; total.visits += visits.length;
      let batch = db.batch(), n = 0;
      const flush = async () => { if (n && apply) await batch.commit(); batch = db.batch(); n = 0; };
      for (const v of visits) {
        const patch = planVisit(v.data, FieldValue.serverTimestamp());
        if (!patch) continue;
        if (patch.propertyKey) total.keyAdded++;
        if (patch.statsAppliedAt) total.markerAdded++;
        if (patch.durationSec != null) total.durationAdded++;
        if (apply) { batch.update(v.ref, patch); if (++n >= 400) await flush(); }
        // keep the in-memory copy current so stats below use the new keys
        Object.assign(v.data, { ...patch, statsAppliedAt: v.data.statsAppliedAt || (patch.statsAppliedAt ? true : undefined) });
      }
      await flush();
      const stats = buildStatsFromVisits(visits);
      for (const [key, s] of Object.entries(stats)) {
        total.statsDocs++;
        if (apply) await co.collection("propertyStats").doc(key).set({
          propertyKey: key, ...s, windowSize: core.C.STATS_WINDOW, updatedAt: FieldValue.serverTimestamp() });
      }
    }
    console.log(JSON.stringify(total));
    console.log(apply ? "Done." : "Dry run only - nothing written. Re-run with --apply to write.");
  })().catch((e) => { console.error(e); process.exit(1); });
}
