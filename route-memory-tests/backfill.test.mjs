// Pure tests for the backfill's decisions (no database, no credentials).
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
const require = createRequire(import.meta.url);
const bf = require("../functions/routeMemoryBackfill.js");
const T = (ms) => ({ toMillis: () => ms });
let pass = 0, fail = 0;
const t = (name, ok, detail = "") => { ok ? pass++ : fail++; console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : "  " + detail}`); };
const M = "MARK";

// old completed app visit with customer
let p = bf.planVisit({ outcome: "completed", source: "app", customerId: "c1", stopId: "s1", arrivedAt: T(0), completedAt: T(300000) }, M);
t("old completed visit: gets propertyKey = customerId", p.propertyKey === "c1");
t("old completed visit: marker + preRouteMemory set (trigger will skip it)", p.statsAppliedAt === M && p.preRouteMemory === true);
t("old completed visit: durationSec = 300", p.durationSec === 300);
t("never invents flag fields", !("flagged" in p) && !("flagRatio" in p) && !("avgBeforeSec" in p));

p = bf.planVisit({ outcome: "completed", source: "app", stopId: "s9", arrivedAt: T(0), completedAt: T(60000) }, M);
t("no customer: propertyKey falls back to stopId", p.propertyKey === "s9");

p = bf.planVisit({ outcome: "completed", source: "recovered_from_logs", customerId: "c1", arrivedAt: T(0), completedAt: T(9000000) }, M);
t("recovered_from_logs: marked processed but NO durationSec (excluded)", p.statsAppliedAt === M && !("durationSec" in p));

p = bf.planVisit({ outcome: "completed", source: "app", customerId: "c1", completedAt: T(5000) }, M);
t("owner-ticked (no arrival): marked, no durationSec", p.statsAppliedAt === M && !("durationSec" in p));

p = bf.planVisit({ outcome: "skipped", customerId: "c1", skippedAt: T(1) }, M);
t("skipped: only propertyKey added, no marker", p.propertyKey === "c1" && !("statsAppliedAt" in p));

t("already processed + has key: untouched", bf.planVisit({ outcome: "completed", statsAppliedAt: T(1), propertyKey: "c1", customerId: "c1", completedAt: T(2) }, M) === null);
t("already processed, missing key: only key added", Object.keys(bf.planVisit({ outcome: "completed", statsAppliedAt: T(1), customerId: "c1", completedAt: T(2) }, M)).join() === "propertyKey");
t("nothing to key on and not completed: untouched", bf.planVisit({ outcome: "in_progress" }, M) === null);

// stats
const mk = (id, key, a, d, extra = {}) => ({ id, data: { outcome: "completed", source: "app", propertyKey: key, arrivedAt: T(a), completedAt: T(a + d * 1000), ...extra } });
const st = bf.buildStatsFromVisits([
  mk("a", "k", 0, 100), mk("b", "k", 1e6, 200), mk("c", "k", 2e6, 300), mk("d", "k", 3e6, 400), mk("e", "k", 4e6, 500), mk("f", "k", 5e6, 600),
  mk("r", "k", 6e6, 9999, { source: "recovered_from_logs" }),
  { id: "o", data: { outcome: "completed", source: "app", propertyKey: "k", completedAt: T(7e6) } },
  { id: "s", data: { outcome: "skipped", propertyKey: "k" } },
  mk("z", "other", 0, 50),
]);
t("stats: 6 counting visits (recovered, owner-ticked, skipped excluded)", st.k.visitCount === 6, JSON.stringify(st.k));
t("stats: average of the LAST 5 = (200+300+400+500+600)/5", st.k.avgDurationSec === 400, String(st.k.avgDurationSec));
t("stats: last duration = 600, last visit f", st.k.lastDurationSec === 600 && st.k.lastVisitId === "f");
t("stats: separate property kept separate", st.other.visitCount === 1 && st.other.avgDurationSec === 50);

// safety rails on the CLI (these exit before touching any database)
const run = (args) => { try { execFileSync("node", ["../functions/routeMemoryBackfill.js", ...args], { stdio: "pipe" }); return 0; } catch (e) { return e.status; } };
t("CLI refuses production without the explicit flag", run(["--project", "whyte-routes"]) === 3);
t("CLI refuses when no project is given", run([]) === 2);

console.log(`\n${pass}/${pass + fail} passed`);
process.exit(fail ? 1 : 0);
