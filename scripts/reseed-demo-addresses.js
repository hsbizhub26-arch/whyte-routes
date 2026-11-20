#!/usr/bin/env node
/**
 * Replace York Region demo addresses on the App Review demo account with
 * neutral Toronto-area industrial addresses.
 *
 * DRY RUN BY DEFAULT: reads, prints a full before/after table, writes nothing.
 * Writes only happen with --apply, and only to fields listed below.
 *
 * What it touches (address + latitude + longitude only):
 *   companies/{id}/customers/{doc}             address, latitude, longitude
 *   companies/{id}/routes/{route}/stops/{stop} address, latitude, longitude
 *   companies/{id}/routes/{route}              start/endAddress + lat/lng
 *                                              (and the embedded `stops` array
 *                                               if a route still carries one)
 *
 * What it never touches: document IDs, `order`, driverId, customerId, status,
 * timestamps, auth, subscription fields. Stop sequence and route structure stay
 * exactly as they are, so the review login keeps working.
 *
 * Same old address -> same new address everywhere (customer + stops + yard),
 * so a customer and its stops stay consistent.
 *
 * Usage (from this repo, uses functions/node_modules/firebase-admin):
 *   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json   # or `gcloud auth application-default login`
 *   node scripts/reseed-demo-addresses.js                      # dry run
 *   node scripts/reseed-demo-addresses.js --company <companyId>  # skip email lookup
 *   node scripts/reseed-demo-addresses.js --apply              # write
 *   node scripts/reseed-demo-addresses.js --apply --clear-stale-timestamps
 *       also deletes enRouteAt/arrivedAt/completedAt on stops that are NOT
 *       status=completed (backlog item: stale 163h timer on Yard/Webber yard).
 *       Dry-run lists them first.
 */
const path = require('path');
const admin = require(path.join(__dirname, '..', 'functions', 'node_modules', 'firebase-admin'));

const PROJECT_ID = 'whyte-routes';
const DEMO_EMAIL = 'applereview@whyte-routes.demo';

const args = process.argv.slice(2);
const APPLY = args.includes('--apply');
const CLEAR_STALE = args.includes('--clear-stale-timestamps');
const companyArg = args.includes('--company') ? args[args.indexOf('--company') + 1] : null;

// Anything matching this is replaced. Everything else is printed as "kept" so you can
// eyeball it. Widen the regex if the dry run shows a leftover local name.
const LOCAL_RE = /newmarket|aurora|richmond\s*hill|markham|vaughan|king\s*city|stouffville|whitchurch|georgina|east\s*gwillimbury|bradford|york\s*region|alfred\s*smith|davis\s*dr|\bL3[XY]\b|\bL4[A-G]\b|\bL6[A-G]\b/i;

// Neutral replacements. Street names are generic; coordinates are real industrial areas
// of Toronto/Ottawa so the map renders sensibly. First entry is used for the yard if the
// yard address matches.
const POOL = [
  { address: '100 Industrial Pkwy, Toronto, ON',   latitude: 43.7156, longitude: -79.5480 },
  { address: '450 Enterprise Blvd, Toronto, ON',   latitude: 43.7258, longitude: -79.5712 },
  { address: '215 Commerce Dr, Toronto, ON',       latitude: 43.7391, longitude: -79.5655 },
  { address: '88 Trade Centre Rd, Toronto, ON',    latitude: 43.7062, longitude: -79.5391 },
  { address: '320 Logistics Way, Toronto, ON',     latitude: 43.7424, longitude: -79.5120 },
  { address: '75 Manufacturers Ln, Toronto, ON',   latitude: 43.7530, longitude: -79.5290 },
  { address: '510 Distribution Ave, Toronto, ON',  latitude: 43.7203, longitude: -79.5886 },
  { address: '160 Depot Rd, Toronto, ON',          latitude: 43.7098, longitude: -79.5240 },
  { address: '640 Business Park Dr, Ottawa, ON',   latitude: 45.3492, longitude: -75.9230 },
  { address: '22 Innovation Ct, Ottawa, ON',       latitude: 45.3411, longitude: -75.9087 },
  { address: '305 Terminal Rd, Ottawa, ON',        latitude: 45.3623, longitude: -75.9391 },
  { address: '18 Gateway Cres, Ottawa, ON',        latitude: 45.3580, longitude: -75.9012 },
  { address: '700 Service Rd, Toronto, ON',        latitude: 43.7320, longitude: -79.5801 },
  { address: '95 Fleet St Unit 4, Toronto, ON',    latitude: 43.7275, longitude: -79.5566 },
];

const map = new Map(); // old address -> POOL entry
function replacementFor(oldAddress) {
  const key = String(oldAddress).trim().toLowerCase();
  if (!map.has(key)) {
    if (map.size >= POOL.length) throw new Error('Replacement pool exhausted - add more entries to POOL');
    map.set(key, POOL[map.size]);
  }
  return map.get(key);
}

const plan = []; // { ref, update, label, from, to }
const staleTs = []; // { ref, label }

function planAddress(ref, label, data, fields) {
  const [aKey, latKey, lngKey] = fields;
  const old = data[aKey];
  if (typeof old !== 'string' || !LOCAL_RE.test(old)) {
    if (typeof old === 'string') console.log(`  keep   ${label}: ${old}`);
    return null;
  }
  const r = replacementFor(old);
  return { ref, label, from: old, to: r.address, update: { [aKey]: r.address, [latKey]: r.latitude, [lngKey]: r.longitude } };
}

async function findCompany(db) {
  if (companyArg) return companyArg;
  const user = await admin.auth().getUserByEmail(DEMO_EMAIL);
  const snap = await db.collection('companies').where('ownerUID', '==', user.uid).get();
  if (snap.empty) throw new Error(`No company owned by ${DEMO_EMAIL} (uid ${user.uid}); pass --company <id>`);
  if (snap.size > 1) throw new Error(`Multiple companies for ${DEMO_EMAIL}: ${snap.docs.map(d => d.id).join(', ')}; pass --company <id>`);
  return snap.docs[0].id;
}

(async () => {
  admin.initializeApp({ projectId: PROJECT_ID });
  const db = admin.firestore();
  const companyId = await findCompany(db);
  const co = db.collection('companies').doc(companyId);
  console.log(`Project ${PROJECT_ID}  company ${companyId}  mode ${APPLY ? 'APPLY' : 'DRY RUN'}\n`);

  console.log('Customers');
  for (const d of (await co.collection('customers').get()).docs) {
    const p = planAddress(d.ref, `customer ${d.id} (${d.get('name')})`, d.data(), ['address', 'latitude', 'longitude']);
    if (p) plan.push(p);
  }

  console.log('\nRoutes');
  for (const rd of (await co.collection('routes').get()).docs) {
    const data = rd.data();
    console.log(` route ${rd.id} (${data.name})`);
    // route-level yard addresses
    const rUpdate = {};
    for (const [a, la, lo] of [['startAddress', 'startLatitude', 'startLongitude'], ['endAddress', 'endLatitude', 'endLongitude']]) {
      const p = planAddress(rd.ref, `route ${rd.id} ${a}`, data, [a, la, lo]);
      if (p) { Object.assign(rUpdate, p.update); plan.push({ ...p, update: p.update }); }
    }
    // legacy embedded stops array, if present
    if (Array.isArray(data.stops) && data.stops.length) {
      let changed = false;
      const next = data.stops.map((s, i) => {
        const p = planAddress(rd.ref, `route ${rd.id} embedded stop[${i}]`, s, ['address', 'latitude', 'longitude']);
        if (!p) return s;
        changed = true;
        plan.push({ ...p, update: null });
        return { ...s, ...p.update };
      });
      if (changed) plan.push({ ref: rd.ref, label: `route ${rd.id} embedded stops array`, from: '(array)', to: '(rewritten, same order/length)', update: { stops: next } });
    }
    // stops subcollection
    for (const sd of (await rd.ref.collection('stops').get()).docs) {
      const s = sd.data();
      const p = planAddress(sd.ref, `  stop ${sd.id} #${s.order}`, s, ['address', 'latitude', 'longitude']);
      if (p) plan.push(p);
      if (CLEAR_STALE && s.status !== 'completed' && (s.enRouteAt || s.arrivedAt || s.completedAt)) {
        staleTs.push({ ref: sd.ref, label: `route ${rd.id} stop ${sd.id} (${s.address}) status=${s.status}` });
      }
    }
  }

  // The embedded-array placeholder entries have update:null and exist only for the table.
  const writes = plan.filter(p => p.update);
  console.log('\n=== PLANNED ADDRESS CHANGES ===');
  for (const p of plan) console.log(`${p.label}\n    ${p.from}\n -> ${p.to}`);
  if (CLEAR_STALE) {
    console.log('\n=== STALE TIMESTAMPS TO DELETE (enRouteAt/arrivedAt/completedAt on non-completed stops) ===');
    staleTs.forEach(s => console.log(s.label));
  }
  console.log(`\n${writes.length} doc write(s), ${staleTs.length} timestamp clear(s), ${map.size} unique address(es) remapped.`);

  if (!APPLY) { console.log('\nDRY RUN - nothing written. Re-run with --apply after reviewing.'); return; }

  // Merge writes per doc, then batch (limit 500 ops/batch).
  const byPath = new Map();
  for (const w of writes) byPath.set(w.ref.path, { ref: w.ref, update: { ...(byPath.get(w.ref.path)?.update || {}), ...w.update } });
  for (const s of staleTs) {
    const cur = byPath.get(s.ref.path) || { ref: s.ref, update: {} };
    const F = admin.firestore.FieldValue;
    Object.assign(cur.update, { enRouteAt: F.delete(), arrivedAt: F.delete(), completedAt: F.delete() });
    byPath.set(s.ref.path, cur);
  }
  const docs = [...byPath.values()];
  for (let i = 0; i < docs.length; i += 400) {
    const b = db.batch();
    docs.slice(i, i + 400).forEach(d => b.update(d.ref, d.update));
    await b.commit();
  }
  console.log(`\nApplied ${docs.length} document update(s).`);
})().catch(e => { console.error(e); process.exit(1); });
