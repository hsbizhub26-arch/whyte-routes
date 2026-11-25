// Shared harness: real Firebase Auth + Firestore + Cloud Functions on the TEST project.
import fs from "node:fs";
import crypto from "node:crypto";
import { createRequire } from "node:module";
import admin from "firebase-admin";
import { initializeApp } from "firebase/app";
import { getAuth, signInWithEmailAndPassword } from "firebase/auth";
import {
  getFirestore, doc, setDoc, updateDoc, getDoc, getDocs, collection, collectionGroup,
  query, where, orderBy, serverTimestamp, Timestamp,
} from "firebase/firestore";
import { getFunctions, httpsCallable } from "firebase/functions";

const require = createRequire(import.meta.url);
export const core = require("../functions/routeMemoryCore.js");
// The committed config carries a placeholder for the test project's web API key (the repo is
// public). The real key lives in test-project.config.local.json (git-ignored) or RM_TEST_API_KEY.
const cfgBase = JSON.parse(fs.readFileSync(new URL("./test-project.config.json", import.meta.url)));
const localUrl = new URL("./test-project.config.local.json", import.meta.url);
export const cfg = { ...cfgBase, ...(fs.existsSync(localUrl) ? JSON.parse(fs.readFileSync(localUrl)) : {}) };
if (process.env.RM_TEST_API_KEY) cfg.apiKey = process.env.RM_TEST_API_KEY;
if (!cfg.apiKey || cfg.apiKey.startsWith("REPLACE_WITH")) {
  throw new Error("Missing test project web API key: put it in route-memory-tests/test-project.config.local.json or set RM_TEST_API_KEY.");
}

// HARD GUARD: this suite may only ever touch the dedicated TEST project.
if (cfg.projectId !== "whyte-routes-test-93ee0") throw new Error(`Refusing to run: ${cfg.projectId} is not the test project.`);
for (const v of ["GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT", "FIREBASE_PROJECT"]) {
  if (process.env[v] && process.env[v] !== cfg.projectId) throw new Error(`Refusing to run: ${v}=${process.env[v]}`);
}
if (process.env.FIRESTORE_EMULATOR_HOST || process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  throw new Error("Refusing to run: an emulator is configured. These tests use the real test project only.");
}

admin.initializeApp({ projectId: cfg.projectId });
export const adb = admin.firestore();
export const aauth = admin.auth();
export { admin, Timestamp, doc, setDoc, updateDoc, getDoc, getDocs, collection, collectionGroup, query, where, orderBy, serverTimestamp, httpsCallable };

export const RUN = crypto.randomBytes(3).toString("hex");
const PASSWORD = crypto.randomBytes(12).toString("base64url") + "aA1!";

export const ts = (m) => Timestamp.fromMillis(m);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const HOUR = 3600e3;

// A signed-in user with their own Auth + Firestore + Functions clients.
export async function makeUser(label, companyId, role) {
  const email = `rmt-${RUN}-${label}@example.test`;
  const rec = await aauth.createUser({ email, password: PASSWORD, displayName: label });
  await adb.collection("users").doc(rec.uid).set({
    email, name: label, role: role === "owner" ? "owner" : "driver", isAdmin: false,
    companyId, companyRole: role,
  });
  const app = initializeApp(cfg, `u-${RUN}-${label}`);
  const auth = getAuth(app);
  await signInWithEmailAndPassword(auth, email, PASSWORD);
  return { label, uid: rec.uid, email, companyId, role, name: label,
           db: getFirestore(app), fn: getFunctions(app, "us-central1") };
}

export async function makeCompany(id, name, tz = "America/Toronto") {
  await adb.collection("companies").doc(id).set({ name, timeZoneIdentifier: tz, isRouteMemoryTest: true });
}

// ── driver-side writes, exactly as the app does them ───────────────
export const visitRef = (db, co, id) => doc(db, "companies", co, "serviceHistory", id);

export async function startVisit(U, o) {
  const id = o.visitId ?? `${o.stopId}_${o.arrivedMs}`;
  const data = {
    stopId: o.stopId, routeId: o.routeId ?? "route1", address: o.address ?? `${o.stopId} Test Street`,
    serviceDate: "2026-10-01", source: "app", recordedVia: "driver_app", outcome: "in_progress",
    createdAt: serverTimestamp(), recordedBy: U.uid, driverId: U.uid, driverName: U.name,
    arrivedAt: ts(o.arrivedMs), propertyKey: o.customerId ?? o.stopId,
  };
  if (o.customerId) data.customerId = o.customerId;
  if (o.runId) data.runId = o.runId;
  await setDoc(visitRef(U.db, U.companyId, id), data, { merge: true });
  return id;
}
export async function finishVisit(U, id, completedMs, extra = {}) {
  await updateDoc(visitRef(U.db, U.companyId, id), { completedAt: ts(completedMs), outcome: "completed", ...extra });
}
export async function waitApplied(co, id, timeoutMs = 150000) {
  const t0 = Date.now();
  for (;;) {
    const s = await adb.collection("companies").doc(co).collection("serviceHistory").doc(id).get();
    if (s.exists && s.data().statsAppliedAt) return s.data();
    if (Date.now() - t0 > timeoutMs) throw new Error(`Timed out waiting for the snapshot on ${id}`);
    await sleep(1500);
  }
}
export async function completeVisit(U, o) {
  const id = await startVisit(U, o);
  await finishVisit(U, id, o.arrivedMs + o.durationSec * 1000, o.extra ?? {});
  return { id, data: await waitApplied(U.companyId, id) };
}
// Sequential history: one completed visit per duration, spaced an hour apart.
export async function buildHistory(U, key, durations, startMs, extra = {}) {
  const out = [];
  let t = startMs;
  for (const d of durations) {
    out.push(await completeVisit(U, { stopId: key.stop ?? key, customerId: key.customer, arrivedMs: t, durationSec: d, ...extra }));
    t += HOUR;
  }
  return out;
}
export const getVisit = async (co, id) =>
  (await adb.collection("companies").doc(co).collection("serviceHistory").doc(id).get()).data();
export const getStats = async (co, key) => {
  const s = await adb.collection("companies").doc(co).collection("propertyStats").doc(key).get();
  return s.exists ? s.data() : null;
};
export const visitsOfProperty = async (co, key) =>
  (await adb.collection("companies").doc(co).collection("serviceHistory").where("propertyKey", "==", key).get())
    .docs.map((d) => ({ id: d.id, v: d.data() }));

export async function denied(p) {
  try { await p; return false; } catch (e) { return /permission-denied|PERMISSION_DENIED|insufficient permissions/i.test(`${e.code} ${e.message}`); }
}
export async function callable(U, name, data) {
  try { return { ok: true, data: (await httpsCallable(U.fn, name)(data)).data }; }
  catch (e) { return { ok: false, code: e.code, message: e.message }; }
}

// ── tiny assertion + report toolkit ──────────────────────────────
export class Check {
  constructor() { this.notes = []; }
  ok(c, msg) { if (!c) throw new Error(`FAILED: ${msg}`); this.notes.push(`ok: ${msg}`); }
  eq(a, b, msg) { if (a !== b) throw new Error(`FAILED: ${msg} (got ${JSON.stringify(a)}, expected ${JSON.stringify(b)})`); this.notes.push(`ok: ${msg} = ${JSON.stringify(a)}`); }
  near(a, b, msg, tol = 1e-6) { if (!(Math.abs(a - b) <= tol)) throw new Error(`FAILED: ${msg} (got ${a}, expected ${b})`); this.notes.push(`ok: ${msg} = ${a}`); }
}

export async function cleanup(companyIds, users) {
  for (const u of users) { try { await aauth.deleteUser(u.uid); await adb.collection("users").doc(u.uid).delete(); } catch {} }
  for (const c of companyIds) { try { await adb.recursiveDelete(adb.collection("companies").doc(c)); } catch {} }
}
