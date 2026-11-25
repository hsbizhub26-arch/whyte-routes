import admin from "firebase-admin";
admin.initializeApp({ projectId: "whyte-routes-test-93ee0" });
const db = admin.firestore(); const c = db.collection("companies").doc("x").collection("serviceHistory");
const qs = [c.where("propertyKey","==","a").orderBy("completedAt","desc"), c.where("driverId","==","a").where("runId","==","b").orderBy("arrivedAt")];
for (let i = 0; i < 40; i++) {
  let bad = 0;
  for (const q of qs) { try { await q.limit(1).get(); } catch (e) { if (/index/i.test(e.message)) bad++; } }
  if (!bad) { console.log("indexes ready"); process.exit(0); }
  await new Promise(r => setTimeout(r, 15000));
}
console.log("indexes still building"); process.exit(1);
