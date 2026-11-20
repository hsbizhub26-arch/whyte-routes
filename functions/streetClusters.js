// ─────────────────────────────────────────────────────────────────────
// STREET CLUSTERS - several customers on one street, on one route.
//
// Detected automatically from the stop addresses (nobody tags them).
// streetKey is a port of TrackingBroadcastService.streetKey in the app,
// so the server and the app agree on what "the same street" means:
//   "157 Crosby Ave, Richmond Hill, ON" -> "crosby ave|richmond hill"
// House number / unit dropped, suffix normalised (Avenue = Ave), town
// kept so a "Main St" in two towns isn't one street. An address that
// can't be read is its own street (never wrongly grouped).
//
// A CLUSTER = 2 or more stops on the same driver's route with the same
// streetKey. Pure functions only - no database access here.
// ─────────────────────────────────────────────────────────────────────

const SUFFIX = {
  avenue: "ave", av: "ave", street: "st", road: "rd", drive: "dr",
  crescent: "cres", cr: "cres", cresc: "cres", court: "crt", ct: "crt",
  boulevard: "blvd", blvrd: "blvd", circle: "cir", circ: "cir", place: "pl",
  lane: "ln", trail: "trl", terrace: "terr", ter: "terr", parkway: "pkwy",
  square: "sq", highway: "hwy", gardens: "gdns", heights: "hts",
  grove: "grv", point: "pt", gate: "gate", way: "way",
};
const DIRECTION = { north: "n", n: "n", south: "s", s: "s", east: "e", e: "e", west: "w", w: "w" };

function streetWords(address, keepCase) {
  if (!address || typeof address !== "string") return null;
  const parts = address.split(",").map((p) => p.trim());
  const first = parts[0];
  if (!first) return null;
  let words = first.split(/\s+/);
  while (words.length && (/^\d/.test(words[0]) || words[0].startsWith("#") || words[0].toLowerCase() === "unit")) {
    words.shift();
  }
  words = words.map((w) => w.replace(/\./g, "")).filter(Boolean);
  const unit = words.findIndex((w, i) => i > 0 && (["unit", "apt", "suite", "ste"].includes(w.toLowerCase()) || w.startsWith("#")));
  if (unit > 0) words = words.slice(0, unit);
  if (!words.length) return null;
  return { words: keepCase ? words : words.map((w) => w.toLowerCase()), town: (parts[1] || "").toLowerCase() };
}

function streetKey(address) {
  const s = streetWords(address, false);
  if (!s) return null;
  const w = s.words.slice();
  const last = w[w.length - 1];
  if (w.length > 1 && DIRECTION[last]) {
    w[w.length - 1] = DIRECTION[last];
    if (SUFFIX[w[w.length - 2]]) w[w.length - 2] = SUFFIX[w[w.length - 2]];
  } else if (w.length > 1 && SUFFIX[last]) {
    w[w.length - 1] = SUFFIX[last];
  }
  return `${w.join(" ")}|${s.town}`;
}

/** The street as the owner typed it, for the text: "Exceller Circle". */
function displayStreet(address) {
  const s = streetWords(address, true);
  return s ? s.words.join(" ") : null;
}

/**
 * @param {Array<{id, order, address, isCompleted, isSkipped}>} stops  one driver's stops on one route
 * @returns {Map<string, {key, street, stopIds: string[]}>} clusters by key, stops in route order (2+ only)
 */
function findClusters(stops) {
  const sorted = stops.slice().sort((a, b) => (a.order || 0) - (b.order || 0));
  const byKey = new Map();
  for (const s of sorted) {
    const key = streetKey(s.address);
    if (!key) continue;
    if (!byKey.has(key)) byKey.set(key, { key, street: displayStreet(s.address), stopIds: [] });
    byKey.get(key).stopIds.push(s.id);
  }
  for (const [k, c] of byKey) if (c.stopIds.length < 2) byKey.delete(k);
  return byKey;
}

function clusterOf(stopId, clusters) {
  for (const c of clusters.values()) if (c.stopIds.includes(stopId)) return c;
  return null;
}

/** Next stop still to do, in route order. */
function nextPending(stops) {
  return stops.slice().sort((a, b) => (a.order || 0) - (b.order || 0))
    .find((s) => !s.isCompleted && !s.isSkipped) || null;
}

module.exports = { streetKey, displayStreet, findClusters, clusterOf, nextPending };
