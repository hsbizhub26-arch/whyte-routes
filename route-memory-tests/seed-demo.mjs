// Sample data for walking through the Route Memory screens on a simulator.
// TEST PROJECT ONLY (lib.mjs refuses anything else). Logins are written to
// $DEMO_CREDS (a private file), never printed.
import fs from "node:fs";
import crypto from "node:crypto";
import { adb, aauth, admin, core, HOUR } from "./lib.mjs";

const CO = "demo-snow-co", TZ = "America/Toronto";
const T = (ms) => admin.firestore.Timestamp.fromMillis(ms);
const pw = () => crypto.randomBytes(9).toString("base64url") + "aA1!";
const creds = {};
async function user(key, email, name, role) {
  const old = await aauth.getUserByEmail(email).catch(() => null);
  if (old) await aauth.deleteUser(old.uid);
  const password = pw();
  const u = await aauth.createUser({ email, password, displayName: name });
  await adb.collection("users").doc(u.uid).set({ email, name, role: role === "owner" ? "owner" : "driver", isAdmin: false, companyId: CO, companyRole: role });
  creds[key] = { email, password, uid: u.uid };
  return u.uid;
}
await adb.recursiveDelete(adb.collection("companies").doc(CO));
const ownerUid = await user("owner", "demo-owner@example.test", "Olive Owner", "owner");
const driverUid = await user("driver", "demo-driver@example.test", "Dee Driver", "driver");
const co = adb.collection("companies").doc(CO);
await co.set({ name: "Demo Snow Co", ownerUID: ownerUid, subscriptionTier: "professional", subscriptionStatus: "active", billingRequired: false, timeZoneIdentifier: TZ, createdAt: T(Date.now()) });
await co.collection("drivers").doc(driverUid).set({ name: "Dee Driver", vehicle: "Truck 1", status: "offline" });

const customers = [
  { id: "c-maple", name: "Maple Ave Dental", address: "12 Maple Ave", lat: 43.651, lng: -79.383, tier: "triple" },
  { id: "c-oak", name: "Oak Street Family", address: "48 Oak Street", lat: 43.655, lng: -79.39, tier: "single" },
  { id: "c-birch", name: "Birch Lane Condos", address: "7 Birch Lane", lat: 43.659, lng: -79.375, tier: "double" },
  { id: "c-cedar", name: "Cedar Court Bakery", address: "150 Cedar Court", lat: 43.662, lng: -79.368, tier: null },
  { id: "c-elm", name: "Elm Park Residence", address: "21 Elm Park Rd", lat: 43.648, lng: -79.397, tier: "double" },
];
for (const c of customers) {
  await co.collection("customers").doc(c.id).set({ name: c.name, address: c.address, latitude: c.lat, longitude: c.lng,
    notificationsOptIn: false, smsEnabled: false, emailEnabled: false, notifyEta: false, notifyCompleted: false, seasons: ["snow"], createdAt: T(Date.now()),
    ...(c.tier ? { sizeTier: c.tier } : {}) });
}
const route = co.collection("routes").doc("demo-route");
await route.set({ name: "North Loop", driverId: driverUid, status: "assigned", createdAt: T(Date.now()), lastUpdated: T(Date.now()), seasons: ["snow"] });
await adb.collection("companies").doc(CO).collection("drivers").doc(driverUid).set({ activeRoute: "demo-route" }, { merge: true });
let order = 0;
for (const c of customers) {
  await route.collection("stops").doc(`stop-${c.id}`).set({ id: `stop-${c.id}`, address: c.address, order: order++, isCompleted: false, isSkipped: false,
    status: "scheduled", customerOptedIn: false, customerId: c.id, customerName: c.name, latitude: c.lat, longitude: c.lng, driverId: driverUid,
    ...(c.tier ? { sizeTier: c.tier } : {}) });
}

// ── history: a finished run from yesterday, with one flagged visit ──
const start = Date.now() - 20 * HOUR;
const runId = "demo-run-yesterday";
const visits = [
  { c: customers[0], min: 8 }, { c: customers[1], min: 5 }, { c: customers[2], skipped: true }, { c: customers[0], key: "flag", min: 14 },
];
// earlier history so predictions have something to learn from
const past = [
  { c: customers[0], durs: [300, 330, 300] }, { c: customers[1], durs: [240, 260] },
];
let t = start - 10 * 24 * HOUR;
for (const p of past) for (const d of p.durs) {
  await co.collection("serviceHistory").add({ stopId: `stop-${p.c.id}`, routeId: "demo-route", propertyKey: p.c.id, customerId: p.c.id, address: p.c.address,
    outcome: "completed", source: "app", driverId: driverUid, driverName: "Dee Driver", arrivedAt: T(t), completedAt: T(t + d * 1000),
    statsAppliedAt: T(t + d * 1000), durationSec: d, serviceDate: "2026-11-10", createdAt: T(t) });
  t += 6 * HOUR;
}
await co.collection("runs").doc(runId).set({ driverId: driverUid, driverName: "Dee Driver", routeId: "demo-route", routeName: "North Loop", shiftId: runId,
  startedAt: T(start), endedAt: T(start + 2 * HOUR), stopCount: 4, snowFactorActive: true, snowFactor: 1.3, predictedTotalSec: 2600, createdAt: T(start) });
let at = start + 600e3;
for (const v of visits) {
  const base = { stopId: `stop-${v.c.id}`, routeId: "demo-route", runId, propertyKey: v.c.id, customerId: v.c.id, address: v.c.address, source: "app",
    driverId: driverUid, driverName: "Dee Driver", serviceDate: "2026-11-24", createdAt: T(at), arrivedAt: T(at) };
  if (v.skipped) { await co.collection("serviceHistory").add({ ...base, outcome: "skipped", skippedAt: T(at + 30e3) }); at += 5 * 60e3; continue; }
  const d = v.min * 60;
  const doc = { ...base, outcome: "completed", completedAt: T(at + d * 1000), statsAppliedAt: T(at + d * 1000), durationSec: d };
  if (v.key === "flag") { Object.assign(doc, { avgBeforeSec: 310, visitCountBefore: 4, flagRatio: d / 310, flagged: true, reasonCode: "deep_snow" }); }
  else { Object.assign(doc, { avgBeforeSec: v.c.id === "c-maple" ? 310 : 250, visitCountBefore: v.c.id === "c-maple" ? 3 : 2, flagRatio: d / (v.c.id === "c-maple" ? 310 : 250), flagged: false }); }
  await co.collection("serviceHistory").add(doc);
  at += (v.min + 6) * 60e3;
}
// propertyStats from the visit records (as the server would compute)
for (const c of customers) {
  const vs = (await co.collection("serviceHistory").where("propertyKey", "==", c.id).get()).docs.map((d) => ({ id: d.id, v: d.data() }))
    .filter((x) => x.v.completedAt && core.isStatsEligible(x.v)).map((x) => ({ id: x.id, order: core.orderKey(x.v, x.id), durationSec: core.durationSecOf(x.v) }))
    .sort((a, b) => core.cmpOrder(a.order, b.order));
  if (!vs.length) continue;
  const s = core.statsFor(vs);
  await co.collection("propertyStats").doc(c.id).set({ propertyKey: c.id, ...s, windowSize: 5, updatedAt: T(Date.now()) });
}
fs.writeFileSync(process.env.DEMO_CREDS, JSON.stringify(creds), { mode: 0o600 });
console.log("demo company ready: owner + driver logins written to the private file");
process.exit(0);
