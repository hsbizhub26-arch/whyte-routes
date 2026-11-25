// Route Memory - pure logic (no Firebase, no I/O).
//
// Everything that decides what a visit's duration is, whether it counts,
// whether it is flagged, what the next visit is predicted to take, and
// how all of that is worded lives here, so the Cloud Functions and the
// test suite use one implementation. The iPhone app has its own copy in
// RouteMemoryCore.swift; the test suite runs both on the same fixtures
// and fails if they ever disagree.
//
// CONSTANTS live in routeMemoryConstants.json (mirrored in
// RouteMemory.swift, checked by the test suite).

const C = require("./routeMemoryConstants.json");

const REASONS = {
  deep_snow: "Deep snow",
  blocked_driveway: "Blocked driveway",
  car_in_way: "Car in the way",
  equipment_issue: "Equipment issue",
  first_visit: "First visit",
  other: "Other",
};

// Firestore Timestamp | Date | millis -> millis (null if absent).
function ms(t) {
  if (t == null) return null;
  if (typeof t === "number") return t;
  if (t instanceof Date) return t.getTime();
  if (typeof t.toMillis === "function") return t.toMillis();
  return null;
}

// completed | skipped | cancelled | incomplete | in_progress.
// An owner correction (correctedOutcome) overrides the stored outcome.
// A visit still "in_progress" after the 18-hour cutoff the app already
// uses (ServiceHistoryRepository.openVisitMaxAge) is "incomplete".
function effectiveStatus(v, nowMs) {
  const o = v.correctedOutcome || v.outcome;
  if (o !== "in_progress") return o;
  const last = ms(v.arrivedAt) ?? ms(v.enRouteAt) ?? ms(v.createdAt);
  if (last != null && nowMs - last >= C.OPEN_VISIT_MAX_AGE_SEC * 1000) return "incomplete";
  return "in_progress";
}

// Real recorded times, with the owner's correction laid over them.
function effectiveTimes(v) {
  return {
    arrivedMs: ms(v.correctedArrivedAt) ?? ms(v.arrivedAt),
    completedMs: ms(v.correctedCompletedAt) ?? ms(v.completedAt),
  };
}

// Whole seconds of true elapsed time (UTC subtraction: daylight saving
// cannot skew it). null when either time is missing or the order is wrong.
function durationSecOf(v) {
  const { arrivedMs, completedMs } = effectiveTimes(v);
  if (arrivedMs == null || completedMs == null || completedMs <= arrivedMs) return null;
  return (completedMs - arrivedMs) / 1000;
}

// ONLY completed visits with real recorded arrival + completion times
// feed averages, predictions and flags. Skipped / cancelled / incomplete
// never do, and neither do visits rebuilt from text logs (times are
// approximate) or ticked done by the owner (no arrival time).
function isStatsEligible(v) {
  if (effectiveStatus(v, Date.now()) !== "completed") return false;
  if (v.source === "recovered_from_logs") return false;
  return durationSecOf(v) != null;
}

// The order visits are compared in is the ORIGINAL recorded completedAt,
// never a corrected one, so a correction can't reshuffle history.
function orderKey(v, id) {
  return [ms(v.completedAt) ?? 0, id];
}
function cmpOrder(a, b) {
  return a[0] - b[0] || (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0);
}

const mean = (xs) => xs.reduce((s, x) => s + x, 0) / xs.length;

// The immutable completion snapshot. `prior` = eligible visits recorded
// BEFORE this one, oldest first: { durationSec } each.
function snapshotFor(durationSec, prior) {
  const last = prior.slice(-C.STATS_WINDOW);
  const avgBeforeSec = last.length ? mean(last.map((p) => p.durationSec)) : null;
  const visitCountBefore = prior.length;
  let flagRatio = null;
  let flagged = false;
  if (visitCountBefore >= C.MIN_VISITS_FOR_FLAG && avgBeforeSec > 0) {
    flagRatio = durationSec / avgBeforeSec;
    flagged = flagRatio >= C.FLAG_RATIO && durationSec - avgBeforeSec > C.FLAG_MIN_OVER_SEC;
  }
  return { durationSec, avgBeforeSec, visitCountBefore, flagRatio, flagged };
}

// Rolling property stats from ALL eligible visits, oldest first.
function statsFor(eligible) {
  const last = eligible.slice(-C.STATS_WINDOW);
  return {
    visitCount: eligible.length,
    avgDurationSec: last.length ? mean(last.map((e) => e.durationSec)) : null,
    lastDurationSec: eligible.length ? eligible[eligible.length - 1].durationSec : null,
  };
}

function defaultSecFor(sizeTier) {
  switch (sizeTier) {
    case "single": return C.DEFAULT_SINGLE_SEC;
    case "double": return C.DEFAULT_DOUBLE_SEC;
    case "triple": return C.DEFAULT_TRIPLE_SEC;
    default: return C.DEFAULT_UNKNOWN_SEC;
  }
}

// Prediction for one stop. snow only ever scales THIS prediction.
function predict(stats, sizeTier, snowActive) {
  const factor = snowActive ? C.SNOW_FACTOR : 1;
  const n = stats && stats.visitCount ? stats.visitCount : 0;
  if (n >= C.MIN_VISITS_FOR_AVERAGE && stats.avgDurationSec != null) {
    return {
      sec: stats.avgDurationSec * factor,
      basis: `avg of last ${Math.min(n, C.STATS_WINDOW)} visits`,
      fromHistory: true,
    };
  }
  return { sec: defaultSecFor(sizeTier) * factor, basis: "estimate", fromHistory: false };
}

const fmtMinSec = (sec) => {
  const s = Math.round(sec);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

// "2.00x usual" - two decimals are display only; the flag decision used
// the raw stored ratio.
const formatFlagTag = (ratio) => `${Number(ratio).toFixed(2)}x usual`;

// Local clock time in the company's zone, e.g. "3:30 AM".
function formatLocalTime(millis, tz) {
  return new Intl.DateTimeFormat("en-US", {
    hour: "numeric", minute: "2-digit", hour12: true, timeZone: tz,
  }).format(new Date(millis)).replace(/ /g, " ");
}
function formatLocalDateTime(millis, tz) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZone: tz,
  }).formatToParts(new Date(millis)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}`;
}

function formatWork(sec) {
  const mins = Math.round(sec / 60);
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  if (h === 0) return `${m} min`;
  return m === 0 ? `${h} hrs` : `${h} hrs ${m} min`;
}

// Run setup summary. Finish = start + total, an absolute instant, so
// it is right across a daylight-saving change; only the DISPLAY is in
// the company's zone. Drive times are not available, so the text says
// "service time only" - never presented as total route time.
function runSummary({ stopCount, totalServiceSec, startMs, tz, driveSec = null }) {
  const withDrive = driveSec != null;
  const total = totalServiceSec + (withDrive ? driveSec : 0);
  const finishMs = startMs + total * 1000;
  const label = withDrive ? "including drive time" : "service time only";
  return {
    finishMs,
    text: `${stopCount} stops · about ${formatWork(total)} of work (${label}) · estimated finish around ${formatLocalTime(finishMs, tz)}`,
  };
}

// CSV (RFC 4180 quoting, plus a leading ' on cells a spreadsheet would
// otherwise run as a formula).
function csvCell(s) {
  let t = s == null ? "" : String(s);
  if (/^[=+\-@\t\r]/.test(t)) t = "'" + t;
  return /[",\n\r]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
}
function reasonLabel(v) {
  if (!v.reasonCode) return "";
  if (v.reasonCode === "other") return v.reasonText || "Other";
  return REASONS[v.reasonCode] || "";
}
// rows: [{ visit, id }] ; returns the CSV text of one run.
function buildRunCsv(rows, tz, nowMs) {
  const head = ["Address", "Driver", "Start", "Complete", "Duration", "Status", "Flagged", "Reason"];
  const out = [head.join(",")];
  for (const { visit: v } of rows) {
    const { arrivedMs, completedMs } = effectiveTimes(v);
    const dur = durationSecOf(v);
    out.push([
      v.address || "",
      v.driverName || "",
      arrivedMs != null ? formatLocalDateTime(arrivedMs, tz) : "",
      completedMs != null ? formatLocalDateTime(completedMs, tz) : "",
      dur != null ? fmtMinSec(dur) : "",
      effectiveStatus(v, nowMs),
      v.flagged === true ? "Yes" : "No",
      reasonLabel(v),
    ].map(csvCell).join(","));
  }
  return out.join("\n") + "\n";
}

// One row of Shift History. `visits` are the run's visit documents.
// Average per stop = time on route / stops completed.
function runRow(run, visits, nowMs) {
  const startMs = ms(run.startedAt);
  const endMs = ms(run.endedAt) ?? nowMs;
  const totalTimeSec = startMs != null ? Math.max(0, Math.round((endMs - startMs) / 1000)) : null;
  let stopsCompleted = 0, stopsSkipped = 0;
  for (const v of visits) {
    const st = effectiveStatus(v, nowMs);
    if (st === "completed") stopsCompleted++;
    else if (st === "skipped") stopsSkipped++;
  }
  return {
    stopsCompleted, stopsSkipped, totalTimeSec,
    avgPerStopSec: stopsCompleted && totalTimeSec != null ? totalTimeSec / stopsCompleted : null,
  };
}

module.exports = {
  C, REASONS, ms, effectiveStatus, effectiveTimes, durationSecOf, isStatsEligible,
  orderKey, cmpOrder, snapshotFor, statsFor, defaultSecFor, predict, fmtMinSec,
  formatFlagTag, formatLocalTime, formatLocalDateTime, formatWork, runSummary,
  csvCell, reasonLabel, buildRunCsv, runRow,
};
