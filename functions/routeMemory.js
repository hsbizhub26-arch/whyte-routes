// Route Memory - server side.
//
//  * applyVisitStats  Firestore trigger. When a visit is completed it
//                     writes the immutable completion snapshot onto the
//                     visit and recomputes the property's rolling stats,
//                     in ONE transaction, guarded by statsAppliedAt so a
//                     double-tap, retry or re-sync applies exactly once.
//  * correctVisit     Owner-only callable. Lays an owner correction over
//                     a completed visit (the original timestamps are
//                     never overwritten), recalculates THAT visit's
//                     snapshot and the property's stats, and writes an
//                     audit record.
//  * recomputePropertyStats  Owner-only callable. Rebuilds a property's
//                     stats from its visit records, paginated, for big
//                     histories.
//
// Why server-side: drivers finish stops with no signal and the phone's
// Firestore cache queues the write. A phone can't run a reliable
// transaction offline, so the numbers are computed here, once the
// completion actually arrives.
//
// All calculations come from routeMemoryCore.js. Stats are ALWAYS
// recomputed from the visit records, never nudged by a delta.

const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const core = require("./routeMemoryCore");

const db = () => admin.firestore();
const FieldValue = admin.firestore.FieldValue;
const PAGE = 500;

const SCAN_FIELDS = ["arrivedAt", "completedAt", "correctedArrivedAt", "correctedCompletedAt",
  "outcome", "correctedOutcome", "source", "enRouteAt", "createdAt"];

const historyCol = (companyId) => db().collection("companies").doc(companyId).collection("serviceHistory");
const statsRef = (companyId, key) => db().collection("companies").doc(companyId).collection("propertyStats").doc(key);

// Every visit of one property that has a completedAt, oldest first,
// reduced to the eligible ones. `get` is tx.get or a plain query get, so
// the same scan serves the transactional and the paginated paths.
// Returns { eligible: [{id, order, durationSec}], scanned }.
async function scanProperty(get, companyId, propertyKey) {
  const eligible = [];
  let scanned = 0;
  let last = null;
  for (;;) {
    let q = historyCol(companyId)
      .where("propertyKey", "==", propertyKey)
      .orderBy("completedAt")
      .select(...SCAN_FIELDS)
      .limit(PAGE);
    if (last) q = q.startAfter(last);
    const snap = await get(q);
    for (const d of snap.docs) {
      scanned++;
      const v = d.data();
      if (core.isStatsEligible(v)) {
        eligible.push({ id: d.id, order: core.orderKey(v, d.id), durationSec: core.durationSecOf(v) });
      }
    }
    if (snap.size < PAGE) break;
    last = snap.docs[snap.docs.length - 1];
  }
  eligible.sort((a, b) => core.cmpOrder(a.order, b.order));
  return { eligible, scanned };
}

const priorTo = (eligible, order, selfId) =>
  eligible.filter((e) => e.id !== selfId && core.cmpOrder(e.order, order) < 0);

function statsDoc(companyId, key, eligible) {
  const s = core.statsFor(eligible);
  return {
    propertyKey: key,
    visitCount: s.visitCount,
    avgDurationSec: s.avgDurationSec,
    lastDurationSec: s.lastDurationSec,
    lastVisitId: eligible.length ? eligible[eligible.length - 1].id : null,
    windowSize: core.C.STATS_WINDOW,
    updatedAt: FieldValue.serverTimestamp(),
  };
}

const keyOf = (v) => v.propertyKey || v.customerId || v.stopId;

// ── completion trigger ───────────────────────────────────────────
async function applyCompletion(companyId, visitId) {
  const vref = historyCol(companyId).doc(visitId);
  return db().runTransaction(async (tx) => {
    const vs = await tx.get(vref);
    if (!vs.exists) return "gone";
    const v = vs.data();
    if (v.statsAppliedAt) return "already-applied";              // idempotency guard
    if (v.outcome !== "completed" || !v.completedAt) return "not-a-completion";
    const key = keyOf(v);
    if (!key) return "no-property-key";

    const { eligible } = await scanProperty((q) => tx.get(q), companyId, key);
    const upd = { statsAppliedAt: FieldValue.serverTimestamp() };
    if (!v.propertyKey) upd.propertyKey = key;

    if (core.isStatsEligible(v)) {
      const order = core.orderKey(v, visitId);
      const snap = core.snapshotFor(core.durationSecOf(v), priorTo(eligible, order, visitId));
      Object.assign(upd, snap);
      // Make sure this visit is in the list even if the scan raced it.
      const all = eligible.some((e) => e.id === visitId)
        ? eligible
        : [...eligible, { id: visitId, order, durationSec: snap.durationSec }]
            .sort((a, b) => core.cmpOrder(a.order, b.order));
      tx.set(statsRef(companyId, key), statsDoc(companyId, key, all));
    }
    tx.update(vref, upd);
    return "applied";
  });
}

exports.applyVisitStats = onDocumentWritten(
  { document: "companies/{companyId}/serviceHistory/{visitId}", retry: true },
  async (event) => {
    const after = event.data && event.data.after;
    if (!after || !after.exists) return;
    const v = after.data();
    // Only a real completion that hasn't been processed. Everything else
    // (en route, arrived, skipped, our own snapshot write) exits here.
    if (v.statsAppliedAt || v.outcome !== "completed" || !v.completedAt) return;
    const result = await applyCompletion(event.params.companyId, event.params.visitId);
    console.log(`applyVisitStats ${event.params.companyId}/${event.params.visitId}: ${result}`);
  }
);

// ── owner-only plumbing ──────────────────────────────────────────
async function requireOwner(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  const u = await db().collection("users").doc(request.auth.uid).get();
  const d = u.exists ? u.data() : null;
  if (!d || d.companyRole !== "owner" || !d.companyId) {
    throw new HttpsError("permission-denied", "Only a company owner can do this.");
  }
  return { uid: request.auth.uid, companyId: d.companyId, email: request.auth.token.email || null };
}

const OUTCOMES = ["completed", "skipped", "cancelled", "incomplete"];
const snapshotOf = (v) => ({
  arrivedAt: v.correctedArrivedAt || v.arrivedAt || null,
  completedAt: v.correctedCompletedAt || v.completedAt || null,
  outcome: v.correctedOutcome || v.outcome || null,
  durationSec: v.durationSec ?? null,
  avgBeforeSec: v.avgBeforeSec ?? null,
  visitCountBefore: v.visitCountBefore ?? null,
  flagRatio: v.flagRatio ?? null,
  flagged: v.flagged ?? null,
});

// ── owner correction ─────────────────────────────────────────────
// data: { visitId, correctedArrivedAtMs?, correctedCompletedAtMs?, correctedOutcome?, note? }
exports.correctVisit = onCall(async (request) => {
  const { uid, companyId, email } = await requireOwner(request);
  const d = request.data || {};
  if (typeof d.visitId !== "string" || !d.visitId) throw new HttpsError("invalid-argument", "visitId required.");
  const aMs = d.correctedArrivedAtMs, cMs = d.correctedCompletedAtMs, outcome = d.correctedOutcome;
  if (aMs == null && cMs == null && outcome == null) throw new HttpsError("invalid-argument", "Nothing to correct.");
  for (const x of [aMs, cMs]) {
    if (x != null && !(Number.isFinite(x) && x > 0)) throw new HttpsError("invalid-argument", "Bad time.");
  }
  if (outcome != null && !OUTCOMES.includes(outcome)) throw new HttpsError("invalid-argument", "Bad status.");
  const note = typeof d.note === "string" ? d.note.slice(0, 200) : null;

  const vref = historyCol(companyId).doc(d.visitId);
  const corrRef = vref.collection("corrections").doc();

  return db().runTransaction(async (tx) => {
    const vs = await tx.get(vref);
    if (!vs.exists) throw new HttpsError("not-found", "No such visit.");
    const v = vs.data();
    // Only a visit that really was completed can be corrected: an owner
    // can fix when it ended, or say it wasn't really completed, but can't
    // conjure a completion that was never recorded.
    if (v.outcome !== "completed" || !v.completedAt) {
      throw new HttpsError("failed-precondition", "Only completed visits can be corrected.");
    }
    const key = keyOf(v);
    const overlay = {};
    if (aMs != null) overlay.correctedArrivedAt = admin.firestore.Timestamp.fromMillis(aMs);
    if (cMs != null) overlay.correctedCompletedAt = admin.firestore.Timestamp.fromMillis(cMs);
    if (outcome != null) overlay.correctedOutcome = outcome;
    const v2 = { ...v, ...overlay };

    const t = core.effectiveTimes(v2);
    if (core.effectiveStatus(v2, Date.now()) === "completed") {
      if (t.arrivedMs == null || t.completedMs == null || t.completedMs <= t.arrivedMs) {
        throw new HttpsError("invalid-argument", "End time must be after start time.");
      }
      if (t.completedMs - t.arrivedMs > 24 * 3600 * 1000) throw new HttpsError("invalid-argument", "A visit can't last over 24 hours.");
      if (t.completedMs > Date.now() + 5 * 60 * 1000) throw new HttpsError("invalid-argument", "End time is in the future.");
    }

    const { eligible } = await scanProperty((q) => tx.get(q), companyId, key);
    const order = core.orderKey(v, vs.id);
    const others = eligible.filter((e) => e.id !== vs.id);
    const nowEligible = core.isStatsEligible(v2);

    const snap = nowEligible
      ? core.snapshotFor(core.durationSecOf(v2), priorTo(others, order, vs.id))
      : { durationSec: null, avgBeforeSec: null, visitCountBefore: priorTo(others, order, vs.id).length, flagRatio: null, flagged: false };
    const list = nowEligible
      ? [...others, { id: vs.id, order, durationSec: snap.durationSec }].sort((a, b) => core.cmpOrder(a.order, b.order))
      : others;

    tx.update(vref, {
      ...overlay, ...snap,
      correctedBy: uid,
      correctedAt: FieldValue.serverTimestamp(),
      propertyKey: key,
    });
    tx.set(statsRef(companyId, key), statsDoc(companyId, key, list));
    tx.set(corrRef, {
      visitId: vs.id, propertyKey: key,
      editorUid: uid, editorEmail: email,
      correctedAt: FieldValue.serverTimestamp(),
      note,
      original: snapshotOf(v),
      corrected: snapshotOf({ ...v2, ...snap }),
    });
    return { ok: true, correctionId: corrRef.id, ...snap };
  });
});

// ── paginated recompute ──────────────────────────────────────────
// Reads the whole history page by page (outside a transaction, so size
// isn't bound by transaction limits), then writes the result only if the
// property's visit count is unchanged since the read - otherwise it
// reads again. Consistency without holding a transaction over a huge scan.
exports.recomputePropertyStats = onCall({ timeoutSeconds: 300 }, async (request) => {
  const { companyId } = await requireOwner(request);
  const key = request.data && request.data.propertyKey;
  if (typeof key !== "string" || !key || key.includes("/")) throw new HttpsError("invalid-argument", "propertyKey required.");

  const countQ = () => historyCol(companyId).where("propertyKey", "==", key).orderBy("completedAt").count();
  for (let attempt = 1; attempt <= 5; attempt++) {
    const { eligible, scanned } = await scanProperty((q) => q.get(), companyId, key);
    const done = await db().runTransaction(async (tx) => {
      const c = (await tx.get(countQ())).data().count;
      if (c !== scanned) return false;                       // history moved: read again
      tx.set(statsRef(companyId, key), statsDoc(companyId, key, eligible));
      return true;
    });
    if (done) {
      const s = core.statsFor(eligible);
      return { ok: true, attempts: attempt, scanned, ...s };
    }
  }
  throw new HttpsError("aborted", "History kept changing; try again.");
});

exports._internal = { applyCompletion, scanProperty };
