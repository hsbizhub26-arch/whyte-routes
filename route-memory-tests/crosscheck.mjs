// Swift (the app's logic) vs JavaScript (the server's logic) on identical fixtures,
// plus the constants parity check. No Firebase access needed.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const require = createRequire(import.meta.url);
const core = require("../functions/routeMemoryCore.js");
const here = path.dirname(fileURLToPath(import.meta.url));
const swiftDir = path.resolve(here, "../WHYTE ROUTES/Services/RouteMemory");
const fx = JSON.parse(fs.readFileSync(path.join(here, "swift-crosscheck/fixtures.json")));
const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR || "/tmp", "rmx-"));
const bin = path.join(tmp, "crosscheck");
execFileSync("swiftc", ["-O", "-o", bin, path.join(swiftDir, "RouteMemory.swift"), path.join(swiftDir, "RouteMemoryCore.swift"), path.join(here, "swift-crosscheck/main.swift")], { stdio: "inherit" });
const swift = JSON.parse(execFileSync(bin, [path.join(here, "swift-crosscheck/fixtures.json")]).toString());

const T = (m) => (m == null ? null : new Date(m));
const vis = (v) => ({ address: v.address, driverName: v.driver, outcome: v.outcome ?? "in_progress", correctedOutcome: v.correctedOutcome,
  arrivedAt: T(v.arrivedMs), completedAt: T(v.completedMs), correctedCompletedAt: T(v.correctedCompletedMs),
  reasonCode: v.reasonCode, reasonText: v.reasonText, flagged: v.flagged });
const js = {
  predict: fx.predict.map((c) => { const p = core.predict(c.count ? { visitCount: c.count, avgDurationSec: c.avg } : null, c.tier, c.snow); return { sec: p.sec, basis: p.basis }; }),
  flagTag: fx.flagTag.map(core.formatFlagTag),
  willFlag: fx.willFlag.map((w) => w.count >= core.C.MIN_VISITS_FOR_FLAG && w.avg > 0 && w.elapsed / w.avg >= core.C.FLAG_RATIO && w.elapsed - w.avg > core.C.FLAG_MIN_OVER_SEC),
  times: fx.times.map((t) => ({ time: core.formatLocalTime(t.ms, t.tz), dateTime: core.formatLocalDateTime(t.ms, t.tz) })),
  work: fx.work.map(core.formatWork),
  minSec: fx.minSec.map(core.fmtMinSec),
  summary: fx.summary.map((s) => { const r = core.runSummary({ stopCount: s.stopCount, totalServiceSec: s.totalSec, startMs: s.startMs, tz: s.tz, driveSec: s.driveSec }); return { finishMs: Math.round(r.finishMs), text: r.text }; }),
  runRow: fx.runRow.map((r) => { const x = core.runRow({ startedAt: r.startMs, endedAt: r.endMs }, r.visits.map(vis), r.nowMs); return { completed: x.stopsCompleted, skipped: x.stopsSkipped, total: x.totalTimeSec, avg: x.avgPerStopSec }; }),
  csv: core.buildRunCsv(fx.csv.rows.map((v) => ({ visit: vis(v) })), fx.csv.tz, fx.csv.nowMs),
};
let bad = 0, n = 0;
const canon = (x) => JSON.stringify(x, (_, v) => (v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => (a < b ? -1 : 1))) : v));
const cmp = (a, b, label) => { n++; if (canon(a) !== canon(b)) { bad++; console.log(`MISMATCH ${label}\n  js:    ${JSON.stringify(a)}\n  swift: ${JSON.stringify(b)}`); } };
for (const k of Object.keys(js)) {
  if (Array.isArray(js[k])) js[k].forEach((x, i) => cmp(x, swift[k][i], `${k}[${i}]`)); else cmp(js[k], swift[k], k);
}
// constants parity: functions/routeMemoryConstants.json <-> RouteMemory.swift
const src = fs.readFileSync(path.join(swiftDir, "RouteMemory.swift"), "utf8");
for (const [k, v] of Object.entries(core.C)) {
  const m = src.match(new RegExp(`static let ${k}\\s*:\\s*\\w+\\s*=\\s*([0-9.]+)`));
  cmp(v, m ? Number(m[1]) : "MISSING-IN-SWIFT", `constant ${k}`);
}
console.log(`\n${n - bad}/${n} Swift-vs-JS comparisons match`);
console.log("\nCSV produced by both:\n" + js.csv);
process.exit(bad ? 1 : 0);
