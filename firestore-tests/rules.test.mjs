import { initializeTestEnvironment, assertFails, assertSucceeds }
  from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, collection, getDocs, query, where } from "firebase/firestore";
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

console.log("\n================ FIRESTORE RULES TEST RESULTS ================");
for (const [s, n] of results) console.log(`${s}  ${n}`);
const failed = results.filter(r => r[0] === "FAIL").length;
console.log(`\n${results.length - failed}/${results.length} passed`);
await env.cleanup();
process.exit(failed ? 1 : 0);
