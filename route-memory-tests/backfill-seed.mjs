// Seeds "pre-Route-Memory" visits (no propertyKey, no snapshot) into company legacy-co on the TEST project.
import { adb, admin, HOUR } from "./lib.mjs";
const T = (ms) => admin.firestore.Timestamp.fromMillis(ms);
const co = adb.collection("companies").doc("legacy-co");
await adb.recursiveDelete(co);
await co.set({ name: "Legacy Co", timeZoneIdentifier: "America/Toronto", ownerUID: "x", isRouteMemoryTest: true });
const base = Date.now() - 60 * 24 * HOUR;
const v = (i, extra) => co.collection("serviceHistory").doc(`legacy-${String(i).padStart(2, "0")}`).set({
  stopId: "s-legacy", routeId: "r", customerId: "c-legacy", address: "1 Legacy Rd", driverId: "d", driverName: "Old Driver", serviceDate: "2026-09-01",
  source: "app", createdAt: T(base + i * 6 * HOUR), ...extra });
for (let i = 0; i < 5; i++) await v(i, { outcome: "completed", arrivedAt: T(base + i * 6 * HOUR), completedAt: T(base + i * 6 * HOUR + 300e3) });
await v(5, { outcome: "completed", arrivedAt: T(base + 5 * 6 * HOUR), completedAt: T(base + 5 * 6 * HOUR + 600e3) });
await v(6, { outcome: "completed", source: "recovered_from_logs", arrivedAt: T(base + 6 * 6 * HOUR), completedAt: T(base + 6 * 6 * HOUR + 9000e3) });
await v(7, { outcome: "completed", completedAt: T(base + 7 * 6 * HOUR) });                                   // owner-ticked: no arrival
await v(8, { outcome: "skipped", arrivedAt: T(base + 8 * 6 * HOUR), skippedAt: T(base + 8 * 6 * HOUR + 30e3) });
console.log("seeded 9 legacy visits");
process.exit(0);
