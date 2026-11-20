// B7: storage rules for video proof (run: npm run test:storage).
import { initializeTestEnvironment, assertFails, assertSucceeds } from "@firebase/rules-unit-testing";
import { ref, uploadBytes } from "firebase/storage";
import { doc, setDoc } from "firebase/firestore";
import { readFileSync } from "fs";

const env = await initializeTestEnvironment({
  projectId: "wr-rules-test",
  storage: { rules: readFileSync("storage.rules", "utf8"), host: "127.0.0.1", port: 9199 },
  firestore: { rules: "rules_version='2'; service cloud.firestore { match /databases/{d}/documents { match /{p=**} { allow read: if true; } } }", host: "127.0.0.1", port: 8080 },
});
await env.withSecurityRulesDisabled(async (ctx) => {
  const db = ctx.firestore();
  await setDoc(doc(db, "users", "drvA"), { companyId: "A", companyRole: "driver" });
  await setDoc(doc(db, "users", "drvA2"), { companyId: "A", companyRole: "driver" });
  await setDoc(doc(db, "users", "ownA"), { companyId: "A", companyRole: "owner" });
  await setDoc(doc(db, "users", "drvB"), { companyId: "B", companyRole: "driver" });
});
const st = (uid) => env.authenticatedContext(uid).storage();
const small = new Uint8Array(1024);
const big = new Uint8Array(21 * 1024 * 1024);
const results = [];
const check = async (n, p) => { try { await p; results.push(["PASS", n]); } catch (e) { results.push(["FAIL", n + " >> " + (e.message || e)]); } };

await check("Driver CAN upload an MP4 proof clip under their own uid",
  assertSucceeds(uploadBytes(ref(st("drvA"), "companies/A/videos/drvA/s1/video_1.mp4"), small, { contentType: "video/mp4" })));
await check("Driver CANNOT upload a non-MP4 file as video",
  assertFails(uploadBytes(ref(st("drvA"), "companies/A/videos/drvA/s1/x.exe"), small, { contentType: "application/octet-stream" })));
await check("Driver CANNOT upload a clip over 20 MB",
  assertFails(uploadBytes(ref(st("drvA"), "companies/A/videos/drvA/s1/big.mp4"), big, { contentType: "video/mp4" })));
await check("Driver CANNOT upload into another driver's folder",
  assertFails(uploadBytes(ref(st("drvA2"), "companies/A/videos/drvA/s1/v.mp4"), small, { contentType: "video/mp4" })));
await check("Driver of company B CANNOT upload into company A",
  assertFails(uploadBytes(ref(st("drvB"), "companies/A/videos/drvB/s1/v.mp4"), small, { contentType: "video/mp4" })));
await check("Photos rule unchanged: driver CAN still upload a JPEG proof photo",
  assertSucceeds(uploadBytes(ref(st("drvA"), "companies/A/photos/drvA/s1/completion_1.jpg"), small, { contentType: "image/jpeg" })));
await check("Photos rule unchanged: a video is still refused in the photos folder",
  assertFails(uploadBytes(ref(st("drvA"), "companies/A/photos/drvA/s1/v.mp4"), small, { contentType: "video/mp4" })));

console.log("\n================ STORAGE RULES TEST RESULTS ================");
for (const [s, n] of results) console.log(`${s}  ${n}`);
const failed = results.filter(r => r[0] === "FAIL").length;
console.log(`\n${results.length - failed}/${results.length} passed`);
await env.cleanup();
process.exit(failed ? 1 : 0);
