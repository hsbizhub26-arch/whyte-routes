import { initializeTestEnvironment, assertFails, assertSucceeds }
  from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, updateDoc, deleteDoc, collection, getDocs, query, where } from "firebase/firestore";
import { readFileSync } from "fs";

const env = await initializeTestEnvironment({
  projectId: "wr-rules-test",
  firestore: { rules: readFileSync("firestore.rules", "utf8"), host: "127.0.0.1", port: 8080 },
});

const A = "companyA", B = "companyB";
const ownerA = "uidOwnerA", driverA = "uidDriverA", driverB = "uidDriverB";

await env.withSecurityRulesDisabled(async (ctx) => {
  const db = ctx.firestore();
  await setDoc(doc(db, "users", ownerA),  { companyId: A, companyRole: "owner" });
  await setDoc(doc(db, "users", driverA), { companyId: A, companyRole: "driver" });
  await setDoc(doc(db, "users", driverB), { companyId: B, companyRole: "driver" });
  await setDoc(doc(db, "companies", A), { name: "Company A" });
  await setDoc(doc(db, "companies", B), { name: "Company B" });
  await setDoc(doc(db, "companies", A, "customers", "cust1"), { name: "A Customer", phone: "+16475550100" });
  await setDoc(doc(db, "companies", B, "customers", "cust2"), { name: "B Customer", phone: "+16475550101" });
  await setDoc(doc(db, "companies", A, "routes", "r1"), { name: "Route A" });
  await setDoc(doc(db, "companies", A, "routes", "r1", "stops", "s1"), { address: "1 A St", driverId: driverA });
  await setDoc(doc(db, "companies", A, "routes", "r1", "stops", "s2"), { address: "2 A St", driverId: "someoneElse" });

  // Live link + its token
  await setDoc(doc(db, "companies", A, "trackingLinks", "liveLink"),
    { active: true, createdAt: new Date(), address: "1 A St", customerName: "A Customer" });
  await setDoc(doc(db, "trackingTokens", "tokenLive"), { companyId: A, linkId: "liveLink" });

  // Superseded link + its token (the re-pointed-stop case)
  await setDoc(doc(db, "companies", A, "trackingLinks", "deadLink"),
    { active: false, superseded: true, createdAt: new Date() });
  await setDoc(doc(db, "trackingTokens", "tokenDead"), { companyId: A, linkId: "deadLink" });
});

const anon    = env.unauthenticatedContext().firestore();
const asDrvA  = env.authenticatedContext(driverA).firestore();
const asDrvB  = env.authenticatedContext(driverB).firestore();

const results = [];
const check = async (name, promise) => {
  try { await promise; results.push(["PASS", name]); }
  catch (e) { results.push(["FAIL", name + "  >> " + (e.message || e)]); }
};

// ---- Cross-tenant isolation ----
await check("Driver of B CANNOT read company A's customer",
  assertFails(getDoc(doc(asDrvB, "companies", A, "customers", "cust1"))));
await check("Driver of B CANNOT read company A's route",
  assertFails(getDoc(doc(asDrvB, "companies", A, "routes", "r1"))));
await check("Driver of B CANNOT list company A's stops",
  assertFails(getDocs(collection(asDrvB, "companies", A, "routes", "r1", "stops"))));
await check("Driver of B CANNOT read company A's company doc",
  assertFails(getDoc(doc(asDrvB, "companies", A))));
await check("Anonymous CANNOT read a customer record",
  assertFails(getDoc(doc(anon, "companies", A, "customers", "cust1"))));
await check("Anonymous CANNOT list customers",
  assertFails(getDocs(collection(anon, "companies", A, "customers"))));

// ---- Driver scoping within their OWN company ----
await check("Driver A CAN list only their own assigned stops",
  assertSucceeds(getDocs(query(collection(asDrvA, "companies", A, "routes", "r1", "stops"),
    where("driverId", "==", driverA)))));
await check("Driver A CANNOT list the whole stops collection unfiltered",
  assertFails(getDocs(collection(asDrvA, "companies", A, "routes", "r1", "stops"))));

// ---- Tracking tokens ----
await check("Anonymous CAN resolve a token for a LIVE link",
  assertSucceeds(getDoc(doc(anon, "trackingTokens", "tokenLive"))));
await check("Anonymous CANNOT resolve a token for a SUPERSEDED link",
  assertFails(getDoc(doc(anon, "trackingTokens", "tokenDead"))));
await check("Anonymous CANNOT ENUMERATE tokens (list denied)",
  assertFails(getDocs(collection(anon, "trackingTokens"))));
await check("Anonymous CANNOT write/repoint a token",
  assertFails(setDoc(doc(anon, "trackingTokens", "tokenLive"), { companyId: B, linkId: "x" })));
await check("Anonymous CAN read the LIVE tracking link itself",
  assertSucceeds(getDoc(doc(anon, "companies", A, "trackingLinks", "liveLink"))));
await check("Anonymous CANNOT read a SUPERSEDED tracking link",
  assertFails(getDoc(doc(anon, "companies", A, "trackingLinks", "deadLink"))));
await check("Anonymous CANNOT list tracking links",
  assertFails(getDocs(collection(anon, "companies", A, "trackingLinks"))));

// ---- Privilege escalation ----
await check("Driver B CANNOT repoint their own user doc at company A",
  assertFails(setDoc(doc(asDrvB, "users", driverB), { companyId: A, companyRole: "owner" })));
await check("Driver B CANNOT overwrite another user's document",
  assertFails(setDoc(doc(asDrvB, "users", ownerA), { companyId: B, companyRole: "driver" })));

// ---- Company settings an owner may change (SMS sender name) ----
const asOwnerA = env.authenticatedContext(ownerA).firestore();
await check("Owner A CAN turn off business name in texts on their own company",
  assertSucceeds(updateDoc(doc(asOwnerA, "companies", A), { smsShowBusinessName: false })));
await check("Driver A CANNOT change the SMS sender-name setting",
  assertFails(updateDoc(doc(asDrvA, "companies", A), { smsShowBusinessName: true })));
await check("Owner A CANNOT smuggle a tier upgrade in with the setting",
  assertFails(updateDoc(doc(asOwnerA, "companies", A), { smsShowBusinessName: true, subscriptionTier: "premiumPlus" })));
await check("Owner A CANNOT change company B's setting",
  assertFails(updateDoc(doc(asOwnerA, "companies", B), { smsShowBusinessName: false })));

// ---- Permanent service history (append-only) ----
const H = (db, id) => doc(db, "companies", A, "serviceHistory", id);
const visitBase = {
  stopId: "s1", routeId: "r1", address: "1 A St", driverId: driverA,
  serviceDate: "2026-11-18", source: "app", recordedBy: driverA,
  recordedVia: "driver_app", outcome: "in_progress",
};
await check("Driver A CAN create a history record for their own stop",
  assertSucceeds(setDoc(H(asDrvA, "v1"), { ...visitBase, enRouteAt: new Date("2026-11-18T20:00:00Z") })));
await check("Driver A CAN add arrived time to it",
  assertSucceeds(setDoc(H(asDrvA, "v1"), { arrivedAt: new Date("2026-11-18T20:10:00Z") }, { merge: true })));
await check("Driver A CAN add done time + GPS and close it as completed",
  assertSucceeds(setDoc(H(asDrvA, "v1"), {
    completedAt: new Date("2026-11-18T20:15:00Z"), outcome: "completed",
    completedLocation: { latitude: 45.3, longitude: -75.9, fixAgeSeconds: 2 },
  }, { merge: true })));
await check("Driver A CANNOT change the done time once written",
  assertFails(setDoc(H(asDrvA, "v1"), { completedAt: new Date("2026-11-18T23:59:00Z") }, { merge: true })));
await check("Owner A CANNOT change the done time either",
  assertFails(setDoc(H(asOwnerA, "v1"), { completedAt: new Date("2026-11-18T23:59:00Z") }, { merge: true })));
await check("Owner A CANNOT change the on-the-way time",
  assertFails(updateDoc(H(asOwnerA, "v1"), { enRouteAt: new Date("2026-11-18T19:00:00Z") })));
await check("Owner A CANNOT move the GPS spot",
  assertFails(updateDoc(H(asOwnerA, "v1"), { completedLocation: { latitude: 1, longitude: 1 } })));
await check("Owner A CANNOT re-open a completed visit",
  assertFails(updateDoc(H(asOwnerA, "v1"), { outcome: "in_progress" })));
await check("Owner A CANNOT rename the customer on a history record",
  assertFails(updateDoc(H(asOwnerA, "v1"), { customerName: "Someone Else" })));
await check("Owner A CANNOT delete a history record",
  assertFails(deleteDoc(H(asOwnerA, "v1"))));
await check("Driver A CANNOT delete a history record",
  assertFails(deleteDoc(H(asDrvA, "v1"))));
await check("Owner A CAN read company history",
  assertSucceeds(getDoc(H(asOwnerA, "v1"))));
await check("Driver A CAN read their own history record",
  assertSucceeds(getDoc(H(asDrvA, "v1"))));
await check("Driver B (other company) CANNOT read company A history",
  assertFails(getDoc(H(asDrvB, "v1"))));
await check("Driver A CANNOT create a record claiming another driver",
  assertFails(setDoc(H(asDrvA, "v2"), { ...visitBase, driverId: "someoneElse" })));
await check("Driver A CANNOT create a 'recovered_from_logs' record from the app",
  assertFails(setDoc(H(asDrvA, "v3"), { ...visitBase, source: "recovered_from_logs" })));
await check("Owner A CANNOT create a 'recovered_from_logs' record from the app",
  assertFails(setDoc(H(asOwnerA, "v4"), { ...visitBase, source: "recovered_from_logs" })));
await check("Driver A CANNOT create an 'owner_entered' record",
  assertFails(setDoc(H(asDrvA, "v5"), { ...visitBase, source: "owner_entered" })));
await check("Owner A CAN create an 'owner_entered' record",
  assertSucceeds(setDoc(H(asOwnerA, "v6"), { ...visitBase, source: "owner_entered", recordedBy: ownerA })));
await check("Driver A CANNOT smuggle an unknown field into history",
  assertFails(setDoc(H(asDrvA, "v7"), { ...visitBase, billedAmount: 500 })));
await check("Driver A CAN set openVisitId on their own stop",
  assertSucceeds(updateDoc(doc(asDrvA, "companies", A, "routes", "r1", "stops", "s1"), { openVisitId: "v1" })));

// ---- Undelivered-text alerts ----
await env.withSecurityRulesDisabled(async (ctx) => {
  await setDoc(doc(ctx.firestore(), "companies", A, "textAlerts", "al1"),
    { customerName: "A Customer", phone: "+16475550100", type: "shiftStart", reason: "blocked", resolved: false });
});
await check("Owner A CAN read text alerts",
  assertSucceeds(getDoc(doc(asOwnerA, "companies", A, "textAlerts", "al1"))));
await check("Driver A CANNOT read text alerts (customer phone numbers)",
  assertFails(getDoc(doc(asDrvA, "companies", A, "textAlerts", "al1"))));
await check("Owner A CAN mark an alert handled",
  assertSucceeds(updateDoc(doc(asOwnerA, "companies", A, "textAlerts", "al1"), { resolved: true, resolvedAt: new Date(), resolvedBy: ownerA })));
await check("Owner A CANNOT rewrite an alert's reason",
  assertFails(updateDoc(doc(asOwnerA, "companies", A, "textAlerts", "al1"), { reason: "fine" })));
await check("Owner A CANNOT delete an alert",
  assertFails(deleteDoc(doc(asOwnerA, "companies", A, "textAlerts", "al1"))));
await check("Owner A CANNOT create a fake alert",
  assertFails(setDoc(doc(asOwnerA, "companies", A, "textAlerts", "al2"), { resolved: false })));

// ---- B5 Season Log owner corrections ----
const SL = (db, night) => doc(db, "companies", A, "seasonLog", night);
await check("Owner A CAN enter a night's snowfall",
  assertSucceeds(setDoc(SL(asOwnerA, "2026-11-18"), { snowfallCm: 12, source: "owner", enteredAt: new Date(), enteredBy: ownerA })));
await check("Owner A CAN read the season log",
  assertSucceeds(getDoc(SL(asOwnerA, "2026-11-18"))));
await check("Owner A CANNOT enter an absurd snowfall (900 cm)",
  assertFails(setDoc(SL(asOwnerA, "2026-11-19"), { snowfallCm: 900, source: "owner", enteredAt: new Date(), enteredBy: ownerA })));
await check("Owner A CANNOT stamp someone else as the author",
  assertFails(setDoc(SL(asOwnerA, "2026-11-19"), { snowfallCm: 5, source: "owner", enteredAt: new Date(), enteredBy: driverA })));
await check("Owner A CANNOT add extra fields",
  assertFails(setDoc(SL(asOwnerA, "2026-11-19"), { snowfallCm: 5, source: "owner", enteredAt: new Date(), enteredBy: ownerA, note: "x" })));
await check("Driver A CANNOT write the season log",
  assertFails(setDoc(SL(asDrvA, "2026-11-20"), { snowfallCm: 5, source: "owner", enteredAt: new Date(), enteredBy: driverA })));
await check("Driver of B CANNOT read company A's season log",
  assertFails(getDoc(SL(asDrvB, "2026-11-18"))));
// Drivers' End Shift answer goes on their OWN shift (existing rule).
await env.withSecurityRulesDisabled(async (ctx) => {
  await setDoc(doc(ctx.firestore(), "companies", A, "drivers", driverA, "shifts", "sh1"),
    { driverId: driverA, startedAt: new Date(), status: "completed", endedAt: new Date() });
});
await check("Driver A CAN add snowfall to their own ended shift",
  assertSucceeds(updateDoc(doc(asDrvA, "companies", A, "drivers", driverA, "shifts", "sh1"), { snowfallCm: 10, snowfallSetAt: new Date() })));
await check("Owner A still CANNOT edit a driver's shift (snowfall goes to seasonLog instead)",
  assertFails(updateDoc(doc(asOwnerA, "companies", A, "drivers", driverA, "shifts", "sh1"), { snowfallCm: 20 })));

console.log("\n================ FIRESTORE RULES TEST RESULTS ================");
for (const [s, n] of results) console.log(`${s}  ${n}`);
const failed = results.filter(r => r[0] === "FAIL").length;
console.log(`\n${results.length - failed}/${results.length} passed`);
await env.cleanup();
process.exit(failed ? 1 : 0);
