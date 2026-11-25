import { adb, makeUser, completeVisit, getStats, getVisit, sleep, cleanup, HOUR } from "./lib.mjs";
const CO = "legacy-co"; let bad = 0;
const chk = (c, m) => { console.log(`${c ? "PASS" : "FAIL"}  ${m}`); if (!c) bad++; };
const U = await makeUser("legacyDriver", CO, "driver");
// 1. a brand-new visit, through the real app path, after the backfill
const r = await completeVisit(U, { stopId: "s-legacy", customerId: "c-legacy", arrivedMs: Date.now() - HOUR, durationSec: 700 });
chk(r.data.avgBeforeSec === 360, `new visit's average-before uses the backfilled history: ${r.data.avgBeforeSec}`);
chk(r.data.visitCountBefore === 6, `...counting the 6 real old visits: ${r.data.visitCountBefore}`);
chk(r.data.flagged === true, `...and it is flagged against that history: ratio ${r.data.flagRatio?.toFixed(2)}`);
chk((await getStats(CO, "c-legacy")).visitCount === 7, "property stats now count 7");
// 2. touching an old backfilled visit must not make the trigger flag it
await adb.collection("companies").doc(CO).collection("serviceHistory").doc("legacy-00").update({ address: "touched" });
await sleep(12000);
const old = await getVisit(CO, "legacy-00");
chk(old.flagged === undefined && old.avgBeforeSec === undefined, "old visit stays unflagged after a later write (trigger skips it)");
chk((await getStats(CO, "c-legacy")).visitCount === 7, "stats unchanged by touching an old visit");
await cleanup([CO], [U]);
console.log(bad ? `${bad} FAILED` : "all backfill live checks passed"); process.exit(bad ? 1 : 0);
