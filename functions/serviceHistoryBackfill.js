// ─────────────────────────────────────────────────────────────────────
// SERVICE HISTORY BACKFILL - rebuild lost visits from the text log.
//
// Before companies/{c}/serviceHistory existed, the only record of a
// finished property was the stop document's single completedAt, which
// the next storm overwrites. For runs that happened before that, the
// one surviving proof of WHEN a property was done is the "completed"
// entry in the stop's notification log
// (routes/{r}/stops/{s}/notifications/{stopId}_completed_{day}),
// written by notifyStop at the moment Done was tapped - even when no
// text actually went out (not opted in, no phone on file).
//
// planRecoveredVisits is PURE: it takes plain data and returns the
// records it would write, so it can be checked by hand (dry run) and
// tested without touching a database. The callable in index.js does
// the reading and, only when asked, the writing.
//
// Rules for a recovered record:
//  - source "recovered_from_logs", recordedVia "backfill_text_log",
//    plus a plain-English recoveryNote, so it can never be mistaken
//    for something the app recorded live;
//  - completedAt = the log entry's time;
//  - the stop's own enRouteAt / arrivedAt are included ONLY when they
//    fall on the same local day and before the done time - otherwise
//    they belong to a later storm and are left out, not guessed;
//  - no GPS: none was recorded then, and the record says so.
// ─────────────────────────────────────────────────────────────────────

function localDay(date, timeZone) {
  return date.toLocaleDateString("en-CA", { timeZone });
}

function utcStamp(date) {
  // Same shape as ServiceHistoryRepository.newVisitId: 20261103T200612Z
  return date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
}

function toDate(v) {
  if (!v) return null;
  if (v instanceof Date) return v;
  if (typeof v.toDate === "function") return v.toDate();
  return null;
}

/**
 * @param {object} input
 * @param {string} input.serviceDate  "YYYY-MM-DD" in the company's time zone
 * @param {string} input.timeZone     e.g. "America/Toronto"
 * @param {Array}  input.routes       [{ id, name, stops: [{ id, data, notifications: [{ id, data }] }] }]
 * @param {object} input.driverNames  { [driverId]: name }
 * @returns {Array<{ visitId, record, summary }>}
 */
function planRecoveredVisits({ serviceDate, timeZone, routes, driverNames = {} }) {
  const plans = [];
  for (const route of routes) {
    for (const stop of route.stops) {
      const s = stop.data || {};
      const doneLogs = (stop.notifications || [])
        .filter((n) => n.data && n.data.type === "completed")
        .map((n) => ({ id: n.id, at: toDate(n.data.createdAt) }))
        .filter((n) => n.at && localDay(n.at, timeZone) === serviceDate)
        .sort((a, b) => a.at - b.at);
      if (doneLogs.length === 0) continue;

      // One storm, one property, one record: the earliest done entry
      // that day. (The log is keyed per stop per day, so there is at
      // most one in practice.)
      const done = doneLogs[0];
      const completedAt = done.at;

      const sameRun = (d) => d && localDay(d, timeZone) === serviceDate && d <= completedAt;
      const enRoute = toDate(s.enRouteAt);
      const arrived = toDate(s.arrivedAt);
      const enRouteAt = sameRun(enRoute) ? enRoute : null;
      const arrivedAt = sameRun(arrived) && (!enRouteAt || arrived >= enRouteAt) ? arrived : null;

      const start = [enRouteAt, arrivedAt, completedAt].filter(Boolean)
        .reduce((a, b) => (a < b ? a : b));
      const visitId = `${stop.id}_${utcStamp(start)}`;

      const record = {
        stopId: stop.id,
        routeId: route.id,
        address: s.address || "",
        serviceDate,
        source: "recovered_from_logs",
        recordedVia: "backfill_text_log",
        outcome: "completed",
        completedAt,
        completedLocationMissing: "Recovered from the text-message log - no GPS was recorded at the time.",
        recoveryNote: `Rebuilt from the "done" entry in the text log (${done.id}). ` +
          "On-the-way and arrived times are included only where the stop still held " +
          "them from this same run.",
      };
      if (route.name) record.routeName = route.name;
      if (s.customerId) record.customerId = s.customerId;
      if (s.customerName) record.customerName = s.customerName;
      if (typeof s.latitude === "number") record.propertyLatitude = s.latitude;
      if (typeof s.longitude === "number") record.propertyLongitude = s.longitude;
      if (s.driverId) {
        record.driverId = s.driverId;
        if (driverNames[s.driverId]) record.driverName = driverNames[s.driverId];
      }
      if (enRouteAt) record.enRouteAt = enRouteAt;
      if (arrivedAt) record.arrivedAt = arrivedAt;

      plans.push({
        visitId,
        record,
        summary: {
          visitId,
          route: route.name || route.id,
          customer: s.customerName || null,
          address: s.address || null,
          onTheWay: enRouteAt ? enRouteAt.toISOString() : null,
          arrived: arrivedAt ? arrivedAt.toISOString() : null,
          done: completedAt.toISOString(),
        },
      });
    }
  }
  plans.sort((a, b) => a.record.completedAt - b.record.completedAt);
  return plans;
}

module.exports = { planRecoveredVisits, localDay, utcStamp };
