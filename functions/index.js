// syncSubscriptionEntitlement
//
// The one trusted write path for companies/{id}.subscriptionTier.
// Firestore rules deliberately only let a platform admin write that
// field directly - a client (even the paying company's own owner)
// can never grant itself a tier. This function is what stands in for
// "platform admin" after a real purchase: it independently
// re-verifies the signed transaction with Apple (never trusts
// whatever the client claims about its own purchase), then writes
// the tier with Admin SDK privileges, which bypass the same rules
// that block the client.
//
// PurchaseManager.swift calls this immediately after every verified
// StoreKit transaction (new purchase, renewal, or restore).

const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const { SignedDataVerifier, Environment } = require("@apple/app-store-server-library");
const fs = require("fs");
const { findClusters, clusterOf, nextPending } = require("./streetClusters");

// Routes on the new street-cluster text flow. SMS Test Route only until
// the owner has seen the real texts; every other route is unchanged.
const STREET_FLOW_ROUTES = ["0SmsTestRoute"];


const path = require("path");

admin.initializeApp();

// Set once via: firebase functions:secrets:set TWILIO_ACCOUNT_SID
// (and the other three below) - the CLI prompts for the value
// directly, it's never typed into a file or committed anywhere.
const TWILIO_ACCOUNT_SID = defineSecret("TWILIO_ACCOUNT_SID");
const TWILIO_AUTH_TOKEN = defineSecret("TWILIO_AUTH_TOKEN");
const TWILIO_PHONE_NUMBER = defineSecret("TWILIO_PHONE_NUMBER");
const RESEND_API_KEY = defineSecret("RESEND_API_KEY");

const BUNDLE_ID = "com.hope.WHYTE-ROUTES";
const APP_APPLE_ID = 6755896122;

// Maps a verified App Store product ID to the exact raw string
// SubscriptionTier.from(_:) in FeatureAccessManager.swift expects on
// companies/{id}.subscriptionTier. "professional" (not "premium") is
// intentional - it's the pre-existing raw value the client already
// maps from, kept here so this function never drifts from what the
// app actually reads.
//
// !! THESE FOUR IDS MUST MATCH, EXACTLY AND CASE-SENSITIVELY:
//      PurchaseManager.productIDs        (WHYTE ROUTES/App/Auth/PurchaseManager.swift)
//      Resources/WhyteRoutes.storekit
//      App Store Connect
//      this map
//    They already drifted once: this map stayed on .v2 after the app
//    moved to .v3, which meant every real purchase was charged by
//    Apple, passed signature verification, and then fell straight
//    into the "Unrecognized product ID" throw below - so the customer
//    paid and got nothing, on every launch and every renewal, silently.
//    Nothing in the build catches this; only a real purchase does.
const PRODUCT_TO_TIER = {
  "whyteroutes.premium.monthly.v3": "professional",
  "whyteroutes.premium.yearly.v3": "professional",
  "whyteroutes.premiumplus.monthly.v3": "premiumPlus",
  "whyteroutes.premiumplus.yearly.v3": "premiumPlus",
};

// A SignedDataVerifier is locked to one Apple environment at
// construction time, but this one deployed function has to accept
// transactions from whichever environment the calling build actually
// ran in - Sandbox once builds go out via TestFlight, and Production
// once live. Rather than guess, try both and use whichever one
// actually succeeds: the JWS can only ever validate against the
// environment that really signed it, so this is safe, not permissive.
//
// Environment.XCODE IS DELIBERATELY NOT IN THIS LIST, and must never
// be added to a deployed build. Apple's library does not verify
// signatures at all for that environment - it early-returns the
// decoded payload - because Xcode's local StoreKit testing signs with
// its own throwaway certificate. Including it made this whole
// function a formality: anyone with an account could hand-craft an
// unsigned JWS naming premiumPlus, call this once, and hold every
// paid tier permanently - which also uncaps the Twilio spend that
// tierRank gates, turning our SMS balance into their budget.
//
// Local StoreKit testing against real infrastructure is not worth
// that. Test purchases through TestFlight/Sandbox instead.
const VERIFIER_ENVIRONMENTS = [Environment.PRODUCTION, Environment.SANDBOX];
let cachedVerifiers = null;
function getVerifiers() {
  if (!cachedVerifiers) {
    const certPath = path.join(__dirname, "certs", "AppleRootCA-G3.cer");
    const rootCert = fs.readFileSync(certPath);
    cachedVerifiers = VERIFIER_ENVIRONMENTS.map(
      (environment) =>
        new SignedDataVerifier(
          [rootCert],
          true, // enableOnlineChecks - also confirms revocation status with Apple, not just signature validity
          environment,
          BUNDLE_ID,
          APP_APPLE_ID
        )
    );
  }
  return cachedVerifiers;
}

async function verifyTransaction(jws) {
  let lastError;
  for (const verifier of getVerifiers()) {
    try {
      return await verifier.verifyAndDecodeTransaction(jws);
    } catch (err) {
      lastError = err;
    }
  }
  throw lastError;
}

exports.syncSubscriptionEntitlement = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const jws = request.data && request.data.signedTransaction;
  if (typeof jws !== "string" || jws.length === 0) {
    throw new HttpsError("invalid-argument", "Missing signedTransaction.");
  }

  let payload;
  try {
    payload = await verifyTransaction(jws);
  } catch (err) {
    console.error("❌ Transaction failed Apple verification:", err);
    throw new HttpsError("invalid-argument", "Could not verify this transaction with Apple.");
  }

  // A refunded/revoked transaction still passes signature
  // verification (the signature only proves Apple issued it at some
  // point) - revocationDate is what actually says whether it's still
  // good today.
  // REVOKED OR EXPIRED -> ACTIVELY DOWNGRADE, don't just decline to grant.
  //
  // This previously returned without touching the company document, so a
  // refund, a cancellation, or a lapsed renewal left subscriptionTier
  // sitting at whatever it last was - forever. The company kept every
  // paid feature indefinitely, and kept consuming the platform's own
  // Twilio balance, because the SMS entitlement reads this same field
  // (tierRank >= 1). Failing "open" on billing is a permanent revenue
  // leak, and in a tight regional trade it spreads by word of mouth.
  const expiresMs = payload.expiresDate ? Number(payload.expiresDate) : null;
  const hasExpired = expiresMs !== null && expiresMs < Date.now();

  if (payload.revocationDate || hasExpired) {
    const reason = payload.revocationDate ? "revoked" : "expired";
    // Resolve the company the same server-side way the grant path does,
    // so a downgrade can never be pointed at someone else's company.
    const uidR = request.auth.uid;
    const userSnapR = await admin.firestore().doc(`users/${uidR}`).get();
    const userDataR = userSnapR.data();

    if (userDataR && userDataR.companyId && userDataR.companyRole === "owner") {
      await admin.firestore().doc(`companies/${userDataR.companyId}`).update({
        subscriptionTier: "starter",
        subscriptionStatus: reason === "revoked" ? "cancelled" : "expired",
      });
      console.log(
        `⬇️  companies/${userDataR.companyId}.subscriptionTier -> starter (${reason}, ` +
        `transaction ${payload.transactionId}, uid ${uidR})`
      );
    }
    return { granted: false, reason };
  }

  const tier = PRODUCT_TO_TIER[payload.productId];
  if (!tier) {
    throw new HttpsError("invalid-argument", `Unrecognized product ID: ${payload.productId}`);
  }

  // The companyId to update is resolved server-side from the
  // caller's own users/{uid} doc - never taken from client input -
  // so nobody can point this at a company they don't belong to.
  const uid = request.auth.uid;
  const userSnap = await admin.firestore().doc(`users/${uid}`).get();
  const userData = userSnap.data();

  if (!userData || !userData.companyId) {
    throw new HttpsError("failed-precondition", "No company associated with this account.");
  }
  if (userData.companyRole !== "owner") {
    throw new HttpsError("permission-denied", "Only a company owner can manage billing.");
  }

  await admin.firestore().doc(`companies/${userData.companyId}`).update({
    subscriptionTier: tier,
    // Written alongside the tier so status and tier can never disagree -
    // a company reinstating after a lapse would otherwise keep reading
    // "expired" while holding a paid tier.
    subscriptionStatus: "active",
  });

  console.log(
    `✅ companies/${userData.companyId}.subscriptionTier -> ${tier} ` +
    `(product ${payload.productId}, uid ${uid})`
  );

  return { granted: true, tier };
});

// sendCustomerNotification
//
// The one trusted path for actually sending a customer SMS/email.
// Everything that matters happens here, not on the client: which
// company this belongs to (resolved from the caller's own uid, never
// trusted from client input), whether that company's subscription
// tier actually includes live notifications, whether the customer
// consented, and whether this exact notification (this stop, this
// type) has already gone out - checked and set inside one Firestore
// transaction so a retry, a second device, or a duplicate client call
// can never cause a second real message to send. The client calls
// this and gets back what actually happened; it never talks to
// Twilio/Resend directly, and never sees their credentials.
//
// Real send failures are recorded as failures, not silently retried
// into a false "sent" - an owner checking notification history is
// looking at what the provider actually said, not what the client
// hoped for.

const TIER_RANK = { starter: 0, professional: 1, premiumPlus: 2 };

function tierRank(subscriptionTier) {
  return TIER_RANK[subscriptionTier] ?? 0;
}

// ── SMS FAIR-USE ALLOWANCE (per business, per calendar month) ─────────
// Counted in billable SEGMENTS, enforced here on the server so no app
// version can get around it. At the cap, customer texts PAUSE for the
// rest of the month - never an overage charge. Email and the tracking
// page keep working. Warnings for the owner are written onto the month's
// usage document (smsWarn80 / smsCapReached) and shown in the app.
const SMS_ALLOWANCE = { professional: 1000, premiumPlus: 3000, enterprise: 3000 };
function smsSegments(body) {
  const text = String(body || "");
  const gsm = /^[\x20-\x7E\n\r]*$/.test(text);   // plain text = GSM-7
  const single = gsm ? 160 : 70, multi = gsm ? 153 : 67;
  return text.length <= single ? 1 : Math.ceil(text.length / multi);
}
// Comped/internal companies (billingRequired === false - the existing
// whitelist flag, e.g. DW Landscaping and the App Review demo) are never
// capped. No second list: this is the same flag the app already uses.
function smsCapExempt(companyData) { return companyData.billingRequired === false; }

// Calendar month in the COMPANY's own time zone, so the allowance resets
// at local midnight on the 1st (not 7 PM the night before, as UTC would).
function usagePeriod(companyData) {
  const tz = (companyData && companyData.timeZoneIdentifier) || "America/Toronto";
  return new Date().toLocaleDateString("en-CA", { timeZone: tz }).slice(0, 7);
}
function usageRef(companyId, companyData) {
  return admin.firestore().doc(`companies/${companyId}/notificationUsage/${usagePeriod(companyData)}`);
}
async function smsAllowanceOk(companyId, companyData) {
  if (smsCapExempt(companyData)) return true;
  const cap = SMS_ALLOWANCE[companyData.subscriptionTier];
  if (!cap) return true;
  const snap = await usageRef(companyId, companyData).get();
  return ((snap.exists && snap.data().smsSegments) || 0) < cap;
}
// RESERVE before sending, inside one transaction, so concurrent sends near
// the cap can never push a business past it. Returns the number of
// segments reserved, or 0 if the text would exceed the allowance (then it
// must not be sent). Comped / uncapped companies are counted for
// reporting but never refused. Warning flags are written once (a flag
// that is already true is left alone).
async function reserveSmsSegments(companyId, companyData, body) {
  const segs = smsSegments(body);
  const ref = usageRef(companyId, companyData);
  const exempt = smsCapExempt(companyData);
  const cap = exempt ? null : SMS_ALLOWANCE[companyData.subscriptionTier];
  return admin.firestore().runTransaction(async (tx) => {
    const d = (await tx.get(ref)).data() || {};
    const used = d.smsSegments || 0;
    if (cap && used + segs > cap) {
      if (!d.smsCapReached) tx.set(ref, { smsCap: cap, smsWarn80: true, smsCapReached: true }, { merge: true });
      return 0;
    }
    const next = used + segs;
    const upd = { smsSegments: next };
    if (cap) {
      upd.smsCap = cap;
      if (next >= cap * 0.8 && !d.smsWarn80) upd.smsWarn80 = true;
      if (next >= cap && !d.smsCapReached) upd.smsCapReached = true;
    }
    tx.set(ref, upd, { merge: true });
    return segs;
  });
}
// Give back a reservation when Twilio refused the request outright (bad
// number, STOP): no message exists and nothing is billed. A text Twilio
// ACCEPTED keeps its reservation even if a carrier later blocks it -
// Twilio still bills accepted-then-undelivered segments.
async function releaseSmsSegments(companyId, companyData, segs) {
  if (!segs) return;
  await usageRef(companyId, companyData).set(
    { smsSegments: admin.firestore.FieldValue.increment(-segs) }, { merge: true });
}

// THREE EVENTS. Shift start, ten minutes out, done.
//
// eta15, enRoute and arrived were removed outright - not disabled by a
// flag, removed - because a flag is a thing someone turns back on by
// accident. Five texts per stop is more than anyone wants at 3am, and
// at $0.0079 a segment a busy company spent more on Twilio than they
// paid in subscription. These three describe the arc a customer
// actually cares about: it started, you're next, it's done.
//
// Each template takes the whole context object rather than positional
// arguments, because the three messages need different fields and the
// old (companyName, time) shape silently passed a clock time into a
// slot that now holds an address.
//
// WHO THE TEXT SAYS IT'S FROM - THE COMPANY'S CHOICE.
//
// Every text opens with a sender name, because carriers expect a
// business text to identify its sender and the toll-free verification
// sample (submitted 2026-11-03) reads "DW Landscaping: ... Reply STOP
// to opt out." Traffic that doesn't look like the approved sample is a
// common cause of carrier filtering on a verified number.
//
// WHICH name is up to each company (Settings > "Show business name in
// customer texts", field smsShowBusinessName):
//   on  (default) -> "DW Landscaping: ..."  - their own business name
//   off           -> "WHYTE ROUTES: ..."    - the product's name
// There is no third "no name" option on purpose: an unidentified text
// is exactly what gets filtered.
const PRODUCT_SMS_BRAND = "WHYTE ROUTES";

function smsBrand(companyData) {
  if (!companyData || companyData.smsShowBusinessName === false) return PRODUCT_SMS_BRAND;
  const name = typeof companyData.name === "string" ? companyData.name.trim() : "";
  return name || PRODUCT_SMS_BRAND;
}

// Opt-out line on every customer SMS, as in the approved sample. Only
// for SMS: "reply STOP" means nothing in an email, so the email copy of
// the same message goes without it.
const SMS_OPT_OUT = " Reply STOP to opt out.";
// ── TEXTS WITH LINKS ARE BLOCKED FROM THE LOCAL 289 NUMBER ───────────
//
// Proven 2026-11-18, not guessed: of every message ever sent from
// +1 289-802-6468, 18 of 18 that contained a link came back
// "undelivered, 30007" (carrier filtering) and 9 of 9 without one were
// delivered. A live A/B test that day gave the same answer, with and
// without "https://". Canadian carriers only allow application traffic
// with links from toll-free numbers and short codes; a local long code
// cannot be registered out of it (10DLC covers US recipients only).
//
// So while the sender is that local number, customer texts go out
// WITHOUT the link - a text that lands beats one that is silently
// eaten - and the link is still minted, so the owner can hand it over
// with Share Link (free) or email. Keyed on the sender itself: the
// moment scripts/sms-sender.sh switches TWILIO_PHONE_NUMBER to the
// approved toll-free number, links come back with no other change.
const UNREGISTERED_LOCAL_SENDERS = ["+12898026468"];
// OFF until the owner chooses it (2026-11-18): she wants the link kept
// in the text. With this false, message content is exactly as before;
// flip to true to send link-free texts from the local number (they
// deliver - the linked ones don't, error 30007).
const STRIP_LINKS_ON_UNREGISTERED_SENDER = false;
function smsLinksBlocked() {
  return STRIP_LINKS_ON_UNREGISTERED_SENDER
    && UNREGISTERED_LOCAL_SENDERS.includes(TWILIO_PHONE_NUMBER.value());
}

function withOptOut(message) {
  return message.endsWith(SMS_OPT_OUT) ? message : `${message}${SMS_OPT_OUT}`;
}

// Worded to stay within ONE 160-character SMS segment with the opt-out
// line and a 44-character tracking link (a second segment doubles the
// cost of every text). The customer's name was dropped for the same
// reason - the approved sample doesn't carry one either.
const MESSAGE_TEMPLATES = {
  shiftStart: (c) => (c.v2 && c.trackingUrl)
    ? `${c.brand}: Your driver has started their shift and is on the way. Track your service live: ${c.trackingUrl}`
    : c.trackingUrl
    ? `${c.brand}: We're on our way for your service today. Track us live: ${c.trackingUrl}`
    // Link-free version for while links are carrier-blocked (see
    // smsLinksBlocked). Still tells the customer what to expect next.
    : `${c.brand}: We're on our way for your service today. We'll text you when we're about 10 minutes away.`,
  // Street cluster: sent to the other customers on a street the moment
  // the truck starts that street. No minute count on purpose - "stop 3
  // of 5" is honest, a number would not be.
  streetArrival: (c) =>
    `${c.brand}: We're on our way to ${c.street}, about 10 minutes away. You're stop ${c.n} of ${c.m} on this street.` +
    (c.trackingUrl ? ` Track us live: ${c.trackingUrl}` : ""),
  eta10: (c) =>
    `${c.brand}: Our crew is about 10 minutes away from ${c.address}.`,
  // A RECEIPT, not just an announcement. The date and time are what
  // make it worth keeping: a customer asking "did they even come on
  // Tuesday?" has the answer in their own message history, and so does
  // the company if it is ever disputed. Stamped in the COMPANY's
  // timezone, not the Cloud Function's - see completedStamp below.
  completed: (c) => c.v2
    ? `${c.brand}: Your service is complete. Thank you!`
    : `${c.brand}: Your service at ${c.address} was completed ${c.completedStamp}. Thank you!`,
};

function buildMessage(type, ctx) {
  const template = MESSAGE_TEMPLATES[type];
  if (!template) return `${ctx.brand}: An update on your service.`;
  return template(ctx);
}

// Real, previously-unnoticed bug fixed here: without an explicit
// timeZone, Node formats using the Cloud Function's own runtime
// timezone (UTC), so a customer would have seen "cleared at 7:15 AM"
// for an actual 3:15 AM Eastern visit. The caller passes the company's
// own timeZoneIdentifier through.
// The service day, in the company's own local time, as YYYY-MM-DD.
//
// This is the missing half of the idempotency key, and its absence was
// a silent production bug. Notifications are deduplicated on a
// document id, that id was `${stopId}_${type}`, and NOTHING ever
// deletes those documents - not the driver, not the owner's "un-tick a
// stop" reset in EditRouteView, which restores the stop to untouched
// and leaves the notification history untouched too.
//
// Routes here are durable objects, not per-day copies: DW Landscaping
// drives the same Aurora route every storm. So the first storm texted
// everyone, and every storm after that returned duplicate_skipped for
// the whole route, forever, with no error anywhere - the owner would
// have seen sends "succeed" and customers would have simply stopped
// hearing from them after day one.
//
// en-CA gives ISO order natively, so this needs no reformatting, and
// it is computed in the COMPANY's timezone rather than the function's
// UTC - otherwise a 9 PM Eastern shift start would already be
// "tomorrow" to the server and a retry twenty minutes later would fall
// on a different key and send twice.
function serviceDayKey(timeZone) {
  return new Date().toLocaleDateString("en-CA", { timeZone });
}

function buildMorningSummaryMessage(brand, completedAtDate, timeZone) {
  // en-US for the same reason as completedStamp: en-CA renders
  // "11:15 p.m." and the trailing period collides with the sentence's.
  const time = completedAtDate.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone });
  return `${brand}: Your driveway was cleared last night at ${time}.`;
}

// Quiet Hours: 11 PM to 6 AM in the company's own local time, only
// when the owner has explicitly opted in (see Settings/quietHoursEnabled).
// Nothing about timing changes for anyone who hasn't turned this on.
function isQuietHours(companyData) {
  if (!companyData.quietHoursEnabled) return false;
  const timeZone = companyData.timeZoneIdentifier || "America/Toronto";
  const hour = parseInt(
    new Intl.DateTimeFormat("en-US", { hour: "numeric", hour12: false, timeZone }).format(new Date()),
    10
  );
  return hour >= 23 || hour < 6;
}

// The types that are only true at the moment they're sent - not
// meaningful to a customer who's asleep, and not meaningful to queue
// for later either (by 6 AM the driver is long past that stop, and a
// tracking link for a finished route shows nothing). These are simply
// skipped during Quiet Hours, same as not_entitled - nothing is
// written, nothing is queued.
const LIVE_ONLY_TYPES = { eta10: true, shiftStart: true, streetArrival: true };

// Sends every queued morning-summary receipt for one company right
// now. Called two ways: inline, the instant any live-hours call comes
// in (so the very first "Completed" tap after 6 AM flushes the whole
// overnight queue immediately, not on a timer) - and from the 6 AM
// scheduled function itself, as the safety net for a shift that ends
// before anyone taps anything after Quiet Hours lifts.
async function flushQueuedMorningSummaries(companyId) {
  let flushCompanyData = null;
  const queueRef = admin.firestore().collection(`companies/${companyId}/queuedMorningSummaries`);
  const queueSnap = await queueRef.get();

  for (const doc of queueSnap.docs) {
    // CLAIM THE DOC BEFORE SENDING, in a transaction.
    //
    // Two callers are DESIGNED to overlap: the 6 AM scheduled function
    // and the inline flush that runs at the top of every live-hours
    // notifyStop. On a 30-driveway night the loop below sits inside
    // ~30 sequential Twilio round-trips, so a second flush starting
    // anywhere in that half-minute window read the same undeleted docs
    // and texted all 30 customers their "cleared your driveway last
    // night" receipt a second time - and double-charged the company's
    // own notificationUsage for the privilege. Two drivers tapping
    // Start Shift in the same second did it without the cron.
    //
    // Deleting inside a transaction makes the claim atomic: exactly
    // one flush can win a given document, and the loser's get() simply
    // finds it gone. Claiming BEFORE the send rather than after is the
    // same trade this file already makes for the per-stop notification
    // doc - a crash mid-send risks one missed receipt rather than ever
    // risking a second real SMS charge.
    const claimed = await admin.firestore().runTransaction(async (tx) => {
      const fresh = await tx.get(doc.ref);
      if (!fresh.exists) return false;
      tx.delete(doc.ref);
      return true;
    });
    if (!claimed) continue;

    const q = doc.data();
    let method = "none";
    let contact = null;
    let result = { accepted: false, failureReason: "No contact information on file." };

    // Same gates as every other customer text: STOP registry first, then
    // the monthly allowance (reserved atomically). Either one falls back
    // to email when the customer has it.
    let smsOk = !!(q.smsEnabled && q.phone);
    let reserved = 0;
    if (smsOk && (await smsOptedOut(q.phone))) smsOk = false;
    if (smsOk) {
      if (!flushCompanyData) flushCompanyData = (await admin.firestore().doc(`companies/${companyId}`).get()).data() || {};
      reserved = await reserveSmsSegments(companyId, flushCompanyData, withOptOut(q.message));
      if (!reserved) smsOk = false;
    }
    if (smsOk) {
      method = "sms";
      contact = q.phone;
      try {
        result = await sendSms(q.phone, withOptOut(q.message), { statusPath: q.notificationRefPath || undefined });
        if (!result.accepted) await releaseSmsSegments(companyId, flushCompanyData, reserved);
        else await rememberSmsRecipient(q.phone, companyId);
      } catch (err) {
        result = { accepted: false, failureReason: err.message || "SMS send threw an error." };
      }
    } else if (q.emailEnabled && q.email) {
      method = "email";
      contact = q.email;
      try {
        result = await sendEmail(q.email, "Your service is complete", q.message);
      } catch (err) {
        result = { accepted: false, failureReason: err.message || "Email send threw an error." };
      }
    }

    const deliveryStatus = method === "none" ? "no_contact_on_file" : (result.accepted ? "accepted" : "failed");

    if (q.notificationRefPath) {
      // Bookkeeping only, and it must not be able to abort the rest of
      // the queue. update() throws NOT_FOUND if the notification doc is
      // gone - and staff can delete it, the rules permit exactly that -
      // which would otherwise take down every summary still queued
      // behind this one, after their texts had already been paid for.
      try {
        await admin.firestore().doc(q.notificationRefPath).update({
          contactMethod: method,
          contactValue: contact || "",
          deliveryStatus,
          providerMessageId: result.providerMessageId || null,
          failureReason: result.failureReason || null,
        });
      } catch (err) {
        console.warn(`⚠️ couldn't update ${q.notificationRefPath} after sending: ${err.message}`);
      }
    }

    if (method !== "none") {
      const period = new Date().toISOString().slice(0, 7);
      const usageRef = admin.firestore().doc(`companies/${companyId}/notificationUsage/${period}`);
      const field = method === "sms" ? "smsCount" : "emailCount";
      const costField = method === "sms" ? "estimatedSmsCostUsd" : "estimatedEmailCostUsd";
      const costPerMessage = method === "sms" ? 0.0079 : 0;
      await usageRef.set({
        [field]: admin.firestore.FieldValue.increment(1),
        [costField]: admin.firestore.FieldValue.increment(costPerMessage),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    // No delete here - the transaction above already claimed and
    // removed this document before a single message went out.
  }
}

// E.164 normalisation, in ONE place.
//
// Customer phone numbers are typed by hand into the owner's app, so
// they arrive as "6472225239", "1 647 222 5239", "(647) 222-5239",
// "647-222-5239" or already-correct "+16472225239". Twilio rejects
// everything except E.164, and the rejection arrives as a failed send
// long after the owner has moved on.
//
// Deliberately NOT "prepend +1 if it doesn't start with +". That
// corrupts any number that already carries a country code in a
// different shape, and it invents a country for input that is simply
// too short to be a phone number. A number this cannot confidently
// normalise is REJECTED rather than guessed at - a failed send with a
// clear reason beats a text to a stranger.
//
// Returns null for anything unusable.
function toE164(raw) {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;

  const isInternational = trimmed.startsWith("+");
  const digits = trimmed.replace(/\D/g, "");
  if (!digits) return null;

  // Already international: trust the caller's country code, only
  // sanity-check the length E.164 actually permits.
  if (isInternational) {
    if (digits.length < 8 || digits.length > 15) return null;
    return `+${digits}`;
  }

  // No country code given. The ONLY shapes we will infer are North
  // American, because that is the market this app serves and guessing
  // any other country from a bare number is not possible.
  const nanp = digits.length === 11 && digits.startsWith("1")
    ? digits.slice(1)
    : digits.length === 10
      ? digits
      : null;
  if (!nanp) return null;

  // NANP structure: area code and exchange both start 2-9. Catches
  // transposed digits and truncated pastes that are the right length
  // but cannot be a real number.
  if (!/^[2-9]\d{2}[2-9]\d{6}$/.test(nanp)) return null;

  return `+1${nanp}`;
}

// ── STOP / START REGISTRY ─────────────────────────────────────────────
// smsOptOuts/{E.164}: written only by the incoming-reply webhook below.
// One sending number serves every company, and a STOP to it blocks that
// phone at the carrier for ALL of them - so the registry is per phone,
// not per company. Every customer-text path checks it BEFORE sending, so
// the app never even attempts a text Twilio would refuse (and the owner
// sees why). START clears it and stamps a fresh consent time.
async function smsOptedOut(phone) {
  const e164 = toE164(phone);
  if (!e164) return false;
  const snap = await admin.firestore().doc(`smsOptOuts/${e164}`).get();
  return snap.exists && snap.data().active === true;
}
// smsRecipients/{E.164} -> the company that last texted this phone, so a
// HELP reply can name the right business. Written after each accepted SMS.
async function rememberSmsRecipient(phone, companyId) {
  const e164 = toE164(phone);
  if (!e164) return;
  await admin.firestore().doc(`smsRecipients/${e164}`).set(
    { companyId, lastTextAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
}

// Where Twilio reports each customer text's FINAL outcome (delivered /
// undelivered / failed) - see twilioStatusCallback. A v2 function is
// also served at this classic URL, which is stable, unlike the run.app
// one; the signature check below depends on it being exact.
const STATUS_CALLBACK_BASE = "https://us-central1-whyte-routes.cloudfunctions.net/twilioStatusCallback";

// `statusPath` = the notification document this text is logged in. When
// given, Twilio calls back with the real outcome and that document (and
// the owner's alert list) is updated - so a text the carrier eats shows
// up in the app instead of sitting there as "accepted" forever.
async function sendSms(to, body, { statusPath } = {}) {
  // Normalised at the single choke point every send path already goes
  // through, so no caller can forget and no two callers can disagree.
  const normalized = toE164(to);
  if (!normalized) {
    console.warn("✖ Refusing to send - phone number is not valid E.164 after normalisation.");
    return {
      accepted: false,
      providerStatus: "invalid_number",
      failureReason: "That phone number doesn't look valid. Check it on the customer's record.",
    };
  }

  const accountSid = TWILIO_ACCOUNT_SID.value();
  const authToken = TWILIO_AUTH_TOKEN.value();
  const from = TWILIO_PHONE_NUMBER.value();

  const auth = Buffer.from(`${accountSid}:${authToken}`).toString("base64");
  const params = new URLSearchParams({ To: normalized, From: from, Body: body });
  if (statusPath) {
    params.set("StatusCallback", `${STATUS_CALLBACK_BASE}?p=${encodeURIComponent(statusPath)}`);
  }

  const response = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
    {
      method: "POST",
      headers: {
        "Authorization": `Basic ${auth}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params.toString(),
    }
  );

  const result = await response.json();
  if (!response.ok) {
    return {
      accepted: false,
      providerStatus: result.status || "error",
      // Twilio's numeric code (e.g. 21610 = recipient replied STOP), so
      // a caller can show it rather than just the prose message.
      errorCode: result.code || null,
      failureReason: result.message || "Twilio request failed",
    };
  }
  // Twilio accepts the request synchronously (status "queued"/"sending") -
  // actual carrier delivery confirmation needs a status callback
  // webhook, not built yet. "accepted" here means Twilio took the
  // message, not that it has landed on the customer's phone.
  return { accepted: true, providerStatus: result.status, providerMessageId: result.sid };
}

// Resend only sends from a domain verified in the Resend account. The old
// sender, updates@whyte-routes.web.app, could never be verified (web.app
// is Google's domain, nobody else can add DNS records to it), so every
// customer email was rejected. send.hsbizhub.com is the verified sending
// domain the other products already use. The display name is the
// company's own brand, the same one their texts open with.
const EMAIL_FROM_ADDRESS = "notifications@send.hsbizhub.com";

function emailFromHeader(fromName) {
  // Strip characters that would break the "Name <address>" header.
  const name = String(fromName || PRODUCT_SMS_BRAND).replace(/[<>"\r\n]/g, "").trim();
  return `${name || PRODUCT_SMS_BRAND} <${EMAIL_FROM_ADDRESS}>`;
}

async function sendEmail(to, subject, body, fromName) {
  const apiKey = RESEND_API_KEY.value();
  if (!apiKey) {
    return { accepted: false, providerStatus: "error", failureReason: "Email is not configured (missing Resend key)." };
  }

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: emailFromHeader(fromName),
      to: [to],
      subject,
      text: body,
    }),
  });

  const result = await response.json();
  if (!response.ok) {
    return { accepted: false, providerStatus: "error", failureReason: result.message || "Resend request failed" };
  }
  return { accepted: true, providerStatus: "accepted", providerMessageId: result.id };
}

// EVERYTHING that actually sends one notification for one stop.
//
// Lifted out of sendCustomerNotification unchanged so the shift-start
// fan-out below can reuse it instead of growing a second copy. That
// matters more than the line count: this is where consent, the
// deleted-customer stop, Quiet Hours, per-type preferences, tier
// entitlement, idempotency and the E.164 check all live. A parallel
// implementation that missed any one of them would be a compliance
// failure nothing in the app would surface - it would just quietly
// text somebody who had opted out.
//
// The caller authenticates and resolves companyId/companyData;
// everything from there down is identical no matter who asked.
async function notifyStop({ companyId, companyData, routeId, stopId, type, extra = {} }) {
  const timeZone = companyData.timeZoneIdentifier || "America/Toronto";
  const quietHours = isQuietHours(companyData);

  // The moment a call comes in outside Quiet Hours, flush whatever's
  // waiting in the overnight queue - this is what makes the very
  // first "Completed" tap after 6 AM instantly release last night's
  // batch, rather than customers waiting on the 6 AM cron.
  if (!quietHours) {
    await flushQueuedMorningSummaries(companyId);
  }

  // Live-only pings (shift start / 10-minute ETA) mean nothing to a
  // sleeping customer and can't be meaningfully queued for later -
  // by 6 AM the driver is long past that stop. Skipped exactly like
  // not_entitled: nothing written, nothing queued.
  if (quietHours && LIVE_ONLY_TYPES[type]) {
    return { deliveryStatus: "skipped_quiet_hours", notificationId: null };
  }

  const stopRef = admin.firestore().doc(`companies/${companyId}/routes/${routeId}/stops/${stopId}`);
  const stopSnap = await stopRef.get();
  const stopData = stopSnap.data();
  if (!stopData) {
    throw new HttpsError("not-found", "Stop not found.");
  }

  // Freshest contact info: the linked Customer record when one
  // exists, same precedence the client already used for the
  // logging-only path this replaces. Per-channel/per-type prefs
  // default true when there's no linked Customer record (legacy
  // stops predating this field) so behavior doesn't regress for
  // them - they only narrow what a real Customer record allows.
  let customerName = stopData.customerName || "Customer";
  let phone = stopData.customerPhone;
  let email = stopData.customerEmail;
  let optedIn = !!stopData.customerOptedIn;
  let smsEnabled = true;
  let emailEnabled = true;
  let notifyEta = true;
  let notifyCompleted = true;

  if (stopData.customerId) {
    const customerSnap = await admin.firestore().doc(`companies/${companyId}/customers/${stopData.customerId}`).get();
    const customerData = customerSnap.data();
    if (customerData) {
      customerName = customerData.name || customerName;
      phone = customerData.phone;
      email = customerData.email;
      optedIn = !!customerData.notificationsOptIn;
      smsEnabled = customerData.smsEnabled !== false;
      emailEnabled = customerData.emailEnabled !== false;
      notifyEta = customerData.notifyEta !== false;
      notifyCompleted = customerData.notifyCompleted !== false;
    } else {
      // THE CUSTOMER RECORD IS GONE. STOP.
      //
      // The defaults above are seeded from the copy cached on the
      // stop, which exists so that legacy stops with no linked
      // Customer at all still work. But this stop DOES name a
      // customer - the record has just been deleted - and without
      // this branch the deletion silently fell through to that
      // cached copy and kept texting the phone number frozen there,
      // with the cached customerOptedIn still true.
      //
      // Which means deleting a customer did not stop contacting
      // them. That is the one thing deleting a customer has to do:
      // it is how an owner acts on "take me off your list", and
      // getting it wrong is a consent failure, not a bug in test
      // data. A missing record is the strongest possible signal not
      // to send, so it is treated as exactly that.
      return { deliveryStatus: "customer_deleted", notificationId: null };
    }
  }

  // GPS-based triggers only - "the backend must verify, not rely on
  // the frontend" (the client already checks this too, but that's
  // not enough on its own). shiftStart and completed are driver
  // button-presses, not location-derived, so they're exempt.
  const GPS_TYPES = { eta10: true };
  if (GPS_TYPES[type]) {
    const driverId = stopData.driverId;
    let lastUpdated = null;
    if (driverId) {
      const driverSnap = await admin.firestore().doc(`companies/${companyId}/drivers/${driverId}`).get();
      lastUpdated = driverSnap.data() && driverSnap.data().lastUpdated;
    }
    const ageMs = lastUpdated ? Date.now() - lastUpdated.toDate().getTime() : Infinity;
    if (ageMs > 5 * 60 * 1000) {
      console.log(`⚠️ notification ${stopId}_${type} (company ${companyId}) -> gps_stale (driver location ${Math.round(ageMs / 1000)}s old)`);
      return { deliveryStatus: "gps_stale", notificationId: null };
    }
  }

  // shiftStart has no individual toggle: a customer who is opted in
  // at all wants to know the crew is coming, and it is the message
  // that carries their tracking link.
  const typePreferenceOk = (type === "eta10" || type === "streetArrival") ? notifyEta
    : type === "completed" ? notifyCompleted
    : true;

  const notificationId = `${stopId}_${type}_${serviceDayKey(timeZone)}`;
  const notificationRef = stopRef.collection("notifications").doc(notificationId);

  // Idempotency: read-check-write inside one transaction, keyed on
  // stopId+type, so a retry, a second device, or GPS jitter calling
  // this twice for the same threshold can never send twice. Written
  // as "sending" BEFORE the real network call - deliberately
  // conservative: a crash mid-send risks one rare missed retry
  // rather than ever risking a second real SMS charge.
  //
  // OUTCOMES THAT NEVER REACHED TWILIO DO NOT BLOCK A RETRY.
  //
  // The key used to be claimed by ANY outcome, including "not_opted_in".
  // On the Nov 3 test all 34 stops were not opted in; the owner can fix
  // that in the app, but the second Start Shift that same day came back
  // "duplicate_skipped" for every stop, because the first attempt had
  // already written a doc for each one. Nothing was sent, nothing was
  // charged, and the customer could still not get a text until tomorrow.
  // Only a send that actually reached Twilio (accepted / sending /
  // queued) may hold the key. A real "failed" is retryable too: Twilio
  // rejected it synchronously, so no message exists and nothing was billed.
  const RETRYABLE_STATUSES = {
    not_opted_in: true,
    type_disabled: true,
    channel_disabled: true,
    no_contact_on_file: true,
    failed: true,
  };
  const shouldSend = await admin.firestore().runTransaction(async (tx) => {
    const existing = await tx.get(notificationRef);
    if (existing.exists && !RETRYABLE_STATUSES[existing.data().deliveryStatus]) return false;
    tx.set(notificationRef, {
      stopId, routeId, customerName, type,
      contactMethod: "pending",
      contactValue: "",
      deliveryStatus: "sending",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });

  if (!shouldSend) {
    return { deliveryStatus: "duplicate_skipped", notificationId };
  }

  // These early exits used to return silently, so the function log for
  // a whole test showed nothing at all for a stop that was never texted.
  // One line each makes "why didn't they get a text?" answerable from
  // the log. Stop/company ids only, never the customer's phone or name.
  if (!optedIn) {
    await notificationRef.update({ deliveryStatus: "not_opted_in" });
    console.log(`⚠️ notification ${notificationId} (company ${companyId}) -> not_opted_in (customer has not opted in to texts)`);
    return { deliveryStatus: "not_opted_in", notificationId };
  }

  if (!typePreferenceOk) {
    await notificationRef.update({ deliveryStatus: "type_disabled" });
    console.log(`⚠️ notification ${notificationId} (company ${companyId}) -> type_disabled`);
    return { deliveryStatus: "type_disabled", notificationId };
  }

  // The sender name every text opens with - the company's own name, or
  // WHYTE ROUTES if they've chosen not to show it. See smsBrand.
  const brand = smsBrand(companyData);

  // The shift-start text IS the tracking link - it is the only
  // message a customer gets before the crew is on their street, so
  // it has to arrive carrying the thing they'd otherwise have to ask
  // for. Minted through the same helper the manual "Send Tracking
  // Link" button uses, so the supersede rules are identical.
  //
  // If minting fails the whole send is abandoned rather than
  // downgraded to a link-less message: a text reading "track live
  // progress here: undefined" is worse than no text, and the
  // notification document written a moment ago is cleared so the
  // idempotency key doesn't permanently block a retry.
  let trackingUrl = null;
  if (type === "shiftStart" || type === "streetArrival") {
    try {
      ({ url: trackingUrl } = await ensureTrackingLink({
        companyId, stopId, stopData, customerName,
      }));
    } catch (err) {
      console.error(`✖ shiftStart link failed for stop ${stopId}:`, err);
      await notificationRef.delete().catch(() => {});
      return { deliveryStatus: "tracking_link_failed", notificationId };
    }
  }

  // The link is still minted above either way; it's only left OUT of
  // an SMS that carriers would block for carrying it. An email copy
  // keeps it - email isn't filtered for it.
  const smsWillCarryLink = !smsLinksBlocked();
  const goesBySms = smsEnabled && phone && phone.trim().length > 0;
  const message = buildMessage(type, {
    brand,
    customerName,
    address: stopData.address || "your address",
    trackingUrl: (goesBySms && !smsWillCarryLink) ? null : trackingUrl,
    ...extra,
    // Formatted here rather than in the template so it lands in the
    // company's own timezone. Reuses the same toLocaleString pattern
    // as buildMorningSummaryMessage, which exists because formatting
    // without an explicit timeZone silently used the function's UTC
    // runtime and mis-stated every overnight visit by several hours.
    // Date and time built SEPARATELY, and the time in en-US on
    // purpose. en-CA renders "11:15 p.m." with trailing periods, which
    // collided with the sentence's own full stop and shipped a receipt
    // reading "11:15 p.m.. Thank you!". en-US gives a clean "11:15 PM".
    completedStamp: (() => {
      const when = new Date();
      const day = when.toLocaleDateString("en-CA", {
        weekday: "short", month: "short", day: "numeric", timeZone,
      });
      const time = when.toLocaleTimeString("en-US", {
        hour: "numeric", minute: "2-digit", timeZone,
      });
      return `${day} at ${time}`;
    })(),
  });

  // Consent and preference both passed, and it's Quiet Hours, and
  // this is the one type worth remembering till morning - queue a
  // morning-summary receipt instead of texting a sleeping customer
  // at 3 AM. The company name is baked into the message text right
  // now (not re-resolved later), so this is already correct for
  // whichever tenant's subscription this is - no separate per-
  // tenant lookup needed at flush time.
  if (quietHours && type === "completed") {
    const summaryMessage = buildMorningSummaryMessage(brand, new Date(), timeZone);
    await admin.firestore().collection(`companies/${companyId}/queuedMorningSummaries`).add({
      phone: smsEnabled ? phone || null : null,
      email: emailEnabled ? email || null : null,
      smsEnabled, emailEnabled,
      message: summaryMessage,
      notificationRefPath: notificationRef.path,
      queuedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await notificationRef.update({ deliveryStatus: "queued_for_morning", message: summaryMessage });
    return { deliveryStatus: "queued_for_morning", notificationId };
  }

  let method = "none";
  let contact = null;
  let result = { accepted: false, failureReason: "No contact information on file." };

  // What was actually sent, for the notification history - the SMS
  // copy carries the opt-out line, the email copy doesn't.
  let sentMessage = message;
  if (smsEnabled && phone && phone.trim().length > 0) {
    method = "sms";
    contact = phone;
    sentMessage = withOptOut(message);
    if (await smsOptedOut(phone)) {
      await notificationRef.update({ contactMethod: "sms", contactValue: phone, deliveryStatus: "sms_opted_out",
        failureReason: "This customer replied STOP. No texts until they reply START.", message: sentMessage });
      console.log(`🚫 notification ${notificationId} (company ${companyId}) -> sms_opted_out`);
      return { deliveryStatus: "sms_opted_out", notificationId };
    }
    const reserved = await reserveSmsSegments(companyId, companyData, sentMessage);
    if (!reserved) {
      // At the cap: fall back to email when the customer has one, so the
      // update still reaches them. Otherwise record a visible pause.
      if (emailEnabled && email && email.trim().length > 0) {
        method = "email"; contact = email; sentMessage = message;
        try { result = await sendEmail(email, `Update on your service`, message, brand); }
        catch (err) { result = { accepted: false, failureReason: err.message || "Email send threw an error." }; }
      } else {
        await notificationRef.update({ contactMethod: "sms", contactValue: phone, deliveryStatus: "sms_allowance_reached",
          failureReason: "Monthly text allowance reached - texts resume on the 1st.", message: sentMessage });
        console.log(`⏸️ notification ${notificationId} (company ${companyId}) -> sms_allowance_reached`);
        return { deliveryStatus: "sms_allowance_reached", notificationId };
      }
    } else try {
      result = await sendSms(phone, sentMessage, { statusPath: notificationRef.path });
      if (!result.accepted) await releaseSmsSegments(companyId, companyData, reserved);
      else await rememberSmsRecipient(phone, companyId);
    } catch (err) {
      result = { accepted: false, failureReason: err.message || "SMS send threw an error." };
    }
  } else if (emailEnabled && email && email.trim().length > 0) {
    method = "email";
    contact = email;
    try {
      result = await sendEmail(email, `Update on your service`, message, brand);
    } catch (err) {
      result = { accepted: false, failureReason: err.message || "Email send threw an error." };
    }
  } else if ((phone && phone.trim().length > 0) || (email && email.trim().length > 0)) {
    // Contact info exists but the customer turned that specific
    // channel off - distinct from genuinely having nothing on file.
    result = { accepted: false, failureReason: "Customer disabled this contact channel." };
  }

  const deliveryStatus = method === "none"
    ? (result.failureReason === "Customer disabled this contact channel." ? "channel_disabled" : "no_contact_on_file")
    : (result.accepted ? "accepted" : "failed");

  await notificationRef.update({
    contactMethod: method,
    contactValue: contact || "",
    deliveryStatus,
    providerMessageId: result.providerMessageId || null,
    failureReason: result.failureReason || null,
    message: sentMessage,
  });

  // Usage/cost tracking - only for an actual attempted provider
  // call (method != "none"), since that's the only case that could
  // have cost money, win or lose. Twilio SMS ≈ $0.0079 USD/segment,
  // Resend email is free under its plan - both approximate, real
  // provider billing is the source of truth, this is for the
  // owner's own at-a-glance cost visibility.
  if (method !== "none") {
    const period = new Date().toISOString().slice(0, 7); // YYYY-MM
    const usageRef = admin.firestore().doc(`companies/${companyId}/notificationUsage/${period}`);
    const field = method === "sms" ? "smsCount" : "emailCount";
    const costField = method === "sms" ? "estimatedSmsCostUsd" : "estimatedEmailCostUsd";
    const costPerMessage = method === "sms" ? 0.0079 : 0;
    await usageRef.set({
      [field]: admin.firestore.FieldValue.increment(1),
      [costField]: admin.firestore.FieldValue.increment(costPerMessage),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }

  console.log(
    `${deliveryStatus === "accepted" ? "✅" : "⚠️"} notification ${notificationId} ` +
    `(company ${companyId}, ${method}) -> ${deliveryStatus}` +
    (result.failureReason ? ` (${result.failureReason})` : "")
  );

  return { deliveryStatus, notificationId };
}

exports.sendCustomerNotification = onCall(
  { secrets: [TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER, RESEND_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }

    const { routeId, stopId, type } = request.data || {};
    if (!routeId || !stopId || !type) {
      throw new HttpsError("invalid-argument", "routeId, stopId, and type are required.");
    }
    // RETIRED TYPES ARE ACCEPTED AND DROPPED, NOT REJECTED.
    //
    // eta15, enRoute and arrived no longer exist server-side, but they
    // are still being called by every copy of the app already on a
    // phone - TestFlight build 25 taps enRoute the moment a driver
    // starts driving and arrived the moment they pull up. Removing the
    // template alone would have turned both of those into a thrown
    // invalid-argument, so the first thing a driver saw on an
    // already-installed build would be an error on the two buttons
    // they press at every single stop.
    //
    // A server cannot assume its clients updated. This returns cleanly
    // and sends nothing: no Twilio call, no notification document, no
    // charge - which is exactly what "removed" has to mean - while old
    // builds keep working silently until they're replaced.
    const RETIRED_TYPES = { eta15: true, enRoute: true, arrived: true };
    if (RETIRED_TYPES[type]) {
      return { deliveryStatus: "retired_type", notificationId: null };
    }
    if (!MESSAGE_TEMPLATES[type]) {
      throw new HttpsError("invalid-argument", `Unknown notification type: ${type}`);
    }

    const uid = request.auth.uid;
    const userSnap = await admin.firestore().doc(`users/${uid}`).get();
    const userData = userSnap.data();
    if (!userData || !userData.companyId) {
      throw new HttpsError("failed-precondition", "No company associated with this account.");
    }
    const companyId = userData.companyId;

    const companySnap = await admin.firestore().doc(`companies/${companyId}`).get();
    const companyData = companySnap.data();
    if (!companyData) {
      throw new HttpsError("failed-precondition", "Company not found.");
    }

    // Live customer notifications are a paid feature - Starter never
    // triggers a real send, regardless of what the client requests.
    if (tierRank(companyData.subscriptionTier) < 1) {
      return { deliveryStatus: "not_entitled", notificationId: null };
    }

    // STREET FLOW (test route only until approved - STREET_FLOW_ROUTES).
    if (STREET_FLOW_ROUTES.includes(routeId)) {
      if (type === "completed") {
        return await notifyStop({ companyId, companyData, routeId, stopId, type, extra: { v2: true } });
      }
      if (type === "eta10") {
        // The truck is ~10 minutes out (the driver app decides that, same
        // as today). On a street with more than one customer, every
        // still-open house on that street gets the street text - once a
        // day each. A house on its own street gets nothing here: its
        // tracking link already shows the truck coming.
        const db = admin.firestore();
        const snap = await db.collection(`companies/${companyId}/routes/${routeId}/stops`).get();
        const me = snap.docs.find((d) => d.id === stopId);
        const driverId = me && me.data().driverId;
        const stops = snap.docs.map((d) => ({ id: d.id, ...d.data() }))
          .filter((x) => !driverId || x.driverId === driverId);
        const cluster = clusterOf(stopId, findClusters(stops));
        if (!cluster) return { deliveryStatus: "no_street_text_single_house", notificationId: null };
        const m = cluster.stopIds.length;
        let mine = { deliveryStatus: "skipped", notificationId: null };
        for (let i = 0; i < m; i++) {
          const id = cluster.stopIds[i];
          const st = stops.find((x) => x.id === id);
          if (!st || st.isCompleted || st.isSkipped) continue;
          const r = await notifyStop({ companyId, companyData, routeId, stopId: id, type: "streetArrival",
            extra: { street: cluster.street, n: i + 1, m } });
          console.log(`🛣️ streetArrival stop ${id} (route ${routeId}) -> ${r.deliveryStatus}`);
          if (id === stopId) mine = r;
        }
        return mine;
      }
    }

    return await notifyStop({ companyId, companyData, routeId, stopId, type });
  }
);

// SHIFT START - the one text that goes out to a whole route at once.
//
// Fired when a driver taps Start Shift, not on a schedule and not when
// the owner builds the route: "your driver has started their route
// today" has to be true at the moment it lands, and only the driver
// knows when that is.
//
// Sent per stop rather than per route because everything that decides
// whether a text is allowed is per CUSTOMER - consent, channel, a
// deleted record, a missing phone number - and because each customer's
// message carries their own tracking link. notifyStop owns all of
// that; this function only decides who is in scope.
//
// WHO IS IN SCOPE: stops on this route assigned to this driver, that
// are not already finished. A driver who starts a second shift later
// the same day does not re-text the stops they already cleared, and
// the day-scoped idempotency key means the ones still open aren't
// texted twice either.
//
// Sequential, not Promise.all. A route is tens of stops, each is an
// SMS billed per segment, and Twilio rate-limits a single number to
// roughly one message per second - firing 40 at once gets a share of
// them rejected, and a rejected shift-start text is one customer who
// never hears the crew is coming. Slower and complete beats fast and
// partial.
exports.sendShiftStartNotifications = onCall(
  { secrets: [TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER, RESEND_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }

    const { routeId } = request.data || {};
    if (!routeId) {
      throw new HttpsError("invalid-argument", "routeId is required.");
    }

    const uid = request.auth.uid;
    const userSnap = await admin.firestore().doc(`users/${uid}`).get();
    const userData = userSnap.data();
    if (!userData || !userData.companyId) {
      throw new HttpsError("failed-precondition", "No company associated with this account.");
    }
    const companyId = userData.companyId;

    const companySnap = await admin.firestore().doc(`companies/${companyId}`).get();
    const companyData = companySnap.data();
    if (!companyData) {
      throw new HttpsError("failed-precondition", "Company not found.");
    }
    if (tierRank(companyData.subscriptionTier) < 1) {
      return { deliveryStatus: "not_entitled", sent: 0, considered: 0 };
    }

    // The route has to belong to this company AND to this caller. The
    // companyId came from the caller's own user document rather than
    // from request.data precisely so that a routeId from another
    // tenant simply isn't found here.
    const routeRef = admin.firestore().doc(`companies/${companyId}/routes/${routeId}`);
    const routeSnap = await routeRef.get();
    if (!routeSnap.exists) {
      throw new HttpsError("not-found", "Route not found.");
    }

    const isStaff = userData.companyRole === "owner" || userData.companyRole === "manager";
    const stopsQuery = isStaff
      ? routeRef.collection("stops")
      : routeRef.collection("stops").where("driverId", "==", uid);
    const stopsSnap = await stopsQuery.get();

    const allOpen = stopsSnap.docs.filter((d) => {
      const data = d.data();
      return !data.isCompleted && !data.isSkipped;
    });

    const plain = stopsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
    // NEW FLOW (test route only until approved - see STREET_FLOW_ROUTES):
    // same audience, cleaner wording.
    const newFlow = STREET_FLOW_ROUTES.includes(routeId);
    const openStops = allOpen;

    let sent = 0;
    const statuses = {};
    for (const stopDoc of openStops) {
      let outcome;
      try {
        const res = await notifyStop({
          companyId, companyData, routeId, stopId: stopDoc.id,
          type: "shiftStart",
          extra: newFlow ? { v2: true } : {},
        });
        outcome = res.deliveryStatus;
        if (outcome === "accepted") sent += 1;
      } catch (err) {
        // One bad stop must not abort the route. The driver has
        // already started driving by the time this runs.
        console.error(`✖ shiftStart failed for stop ${stopDoc.id}:`, err);
        outcome = "error";
      }
      statuses[outcome] = (statuses[outcome] || 0) + 1;
    }

    console.log(
      `📣 shiftStart route ${routeId} (company ${companyId}): ` +
      `${sent}/${openStops.length} accepted ${JSON.stringify(statuses)}`
    );

    return { sent, considered: openStops.length, statuses };
  }
);

// sendMorningSummaries
//
// Safety net for Quiet Hours: flushQueuedMorningSummaries already
// fires the instant a driver taps anything after 6 AM, so most nights
// this finds nothing left to do. It exists for the shift that ends
// before that ever happens - the last stop finished at 4 AM and
// nobody touches the app again, so nothing would otherwise release
// that customer's receipt. Runs once daily at 6 AM in each company's
// own timezone (Cloud Scheduler evaluates the cron per the timeZone
// given here), only for companies that opted into Quiet Hours at all.
exports.sendMorningSummaries = onSchedule(
  {
    schedule: "0 6 * * *",
    timeZone: "America/Toronto",
    secrets: [TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER, RESEND_API_KEY],
  },
  async () => {
    const companiesSnap = await admin.firestore()
      .collection("companies")
      .where("quietHoursEnabled", "==", true)
      .get();

    for (const companyDoc of companiesSnap.docs) {
      await flushQueuedMorningSummaries(companyDoc.id);
    }
  }
);

// sendTestNotification
//
// A deliberate, safe way to prove the real SMS pipeline works without
// touching any customer record, consent, or entitlement check - the
// owner types their own number in Settings and gets back exactly what
// Twilio said, same as a real send. Message is unmistakably marked as
// a test. Rate-limited per company per day so this can't become an
// accidental way to run up a Twilio bill.
const TEST_SENDS_PER_DAY = 10;

// ── The REAL outcome of a message, not just "Twilio took the request".
//
// The Nov 3 bug: Twilio answers the send request at once with status
// "queued", and that answer was reported as "✅ Sent". The carrier then
// rejected every one of those texts about a second later (status
// "undelivered", error 30007) and nothing ever looked again. Twilio's
// own log showed the failure; the app showed green.
//
// For the test path we now wait for the final status before
// answering. Measured on the Nov 3 messages, Twilio reached the final
// status 1-2 seconds after the send, so a 20s cap is generous and
// costs nothing on the success path.
const TWILIO_FINAL_STATUSES = { delivered: true, undelivered: true, failed: true, canceled: true };
const TEST_STATUS_WAIT_MS = 20000;
const TEST_STATUS_POLL_MS = 1500;

// Plain-language meaning of the codes this app has actually hit or is
// about to (the toll-free switch). Anything else falls back to Twilio's
// own error_message plus the docs link.
const TWILIO_ERROR_HELP = {
  21610: "This phone replied STOP to our number, so Twilio won't text it. Reply START from that phone to undo.",
  21211: "Twilio says this isn't a valid phone number.",
  30003: "The phone was unreachable (switched off, no signal, or out of service).",
  30005: "The number doesn't exist or isn't active on a carrier.",
  30006: "That number is a landline or can't receive texts.",
  30007: "The carrier blocked this message as filtered/spam. It's the sender number, not the phone you're texting.",
  30008: "The carrier rejected it for an unknown reason.",
  30032: "Our toll-free sender number isn't verified yet, so carriers block it until verification is approved.",
  30034: "Our sender number isn't registered for business texting (A2P 10DLC).",
};

function describeTwilioError(code, twilioMessage) {
  if (!code) return null;
  const help = TWILIO_ERROR_HELP[code] || twilioMessage || "See Twilio's docs for this code.";
  return `Twilio error ${code}: ${help}`;
}

async function fetchTwilioMessage(sid) {
  const accountSid = TWILIO_ACCOUNT_SID.value();
  const authToken = TWILIO_AUTH_TOKEN.value();
  const auth = Buffer.from(`${accountSid}:${authToken}`).toString("base64");
  const response = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages/${encodeURIComponent(sid)}.json`,
    { headers: { "Authorization": `Basic ${auth}` } }
  );
  const m = await response.json();
  if (!response.ok) throw new Error(m.message || `Twilio lookup failed (${response.status})`);
  return m;
}

// Polls until Twilio reports a final status or the wait runs out.
// Returns the last thing Twilio said, with `final` telling the caller
// whether that is the end of the story.
async function waitForFinalTwilioStatus(sid, maxWaitMs = TEST_STATUS_WAIT_MS) {
  const deadline = Date.now() + maxWaitMs;
  let m = null;
  for (;;) {
    try {
      m = await fetchTwilioMessage(sid);
    } catch (err) {
      console.warn(`⚠️ status lookup for ${sid} failed: ${err.message}`);
    }
    if (m && TWILIO_FINAL_STATUSES[m.status]) break;
    if (Date.now() + TEST_STATUS_POLL_MS > deadline) break;
    await new Promise((r) => setTimeout(r, TEST_STATUS_POLL_MS));
  }
  return testOutcomeFrom(sid, m);
}

// One shape for both the first answer and "Check again".
//
// `accepted` is kept for builds already installed (build 56 and older
// read only that field and show green when it's true). It is now true
// ONLY when the carrier confirmed delivery, so even the old screen can
// no longer show "✅ Sent" for a filtered text - it shows "⚠️ Failed"
// with the real reason in failureReason instead.
function testOutcomeFrom(sid, m) {
  const status = (m && m.status) || "unknown";
  const errorCode = (m && m.error_code) || null;
  const final = !!TWILIO_FINAL_STATUSES[status];
  const delivered = status === "delivered";
  let failureReason = null;
  if (!delivered) {
    failureReason = describeTwilioError(errorCode, m && m.error_message)
      || (final
        ? `Twilio status "${status}" - the message did not reach the phone.`
        : `Not confirmed yet - Twilio status "${status}". The carrier hasn't reported delivery; tap Check Again in a minute.`);
  }
  return {
    accepted: delivered,
    delivered,
    final,
    status,
    errorCode,
    failureReason,
    providerMessageId: sid,
    from: (m && m.from) || null,
  };
}

exports.sendTestNotification = onCall(
  { secrets: [TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }

    const phone = (request.data && request.data.phone || "").trim();
    if (!/^\+[1-9]\d{6,14}$/.test(phone)) {
      throw new HttpsError("invalid-argument", "Phone must be in +1XXXXXXXXXX format.");
    }

    const uid = request.auth.uid;
    const userSnap = await admin.firestore().doc(`users/${uid}`).get();
    const userData = userSnap.data();
    if (!userData || !userData.companyId) {
      throw new HttpsError("failed-precondition", "No company associated with this account.");
    }

    // THE UI GATE WAS THE ONLY GATE. Settings hides this diagnostic
    // behind isPlatformAdmin, but a callable is a public HTTPS endpoint
    // - hiding the button hides nothing. Any signed-in customer could
    // call it directly and spend real money out of the live Twilio
    // balance, to any number they liked, ten times a day per company.
    // The check belongs where it is enforced, not where it is drawn.
    if (userData.platformAdmin !== true) {
      throw new HttpsError("permission-denied", "Test notifications are not available on this account.");
    }
    const companyId = userData.companyId;

    // The company's own calendar day, not UTC's. The UTC key rolled
    // over at 7 PM Eastern, so the Nov 3 evening tests were counted as
    // "Nov 4" - harmless that night, but "10 per day" should mean the
    // day the owner is living in. Same helper the per-stop texts use.
    const companySnap = await admin.firestore().doc(`companies/${companyId}`).get();
    const timeZone = (companySnap.data() && companySnap.data().timeZoneIdentifier) || "America/Toronto";
    const today = serviceDayKey(timeZone);
    const usageRef = admin.firestore().doc(`companies/${companyId}/testNotificationUsage/${today}`);

    const allowed = await admin.firestore().runTransaction(async (tx) => {
      const snap = await tx.get(usageRef);
      const count = (snap.exists && snap.data().count) || 0;
      if (count >= TEST_SENDS_PER_DAY) return false;
      tx.set(usageRef, { count: count + 1, updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
      return true;
    });

    if (!allowed) {
      throw new HttpsError("resource-exhausted", `Limit of ${TEST_SENDS_PER_DAY} test messages per day reached.`);
    }

    let result;
    try {
      // Deliberately CARRIES A LINK. The old test message was plain
      // text, so it sailed through while every real tracking-link text
      // was silently filtered by the carrier (Twilio status
      // "undelivered", error 30007) - the test passed and the product
      // did not. A diagnostic that cannot fail the way production
      // fails is not a diagnostic.
      // The link must be the SAME SHAPE production sends, or the test
      // proves nothing about the thing that is actually failing. It
      // points at a token that does not resolve, which is exactly what
      // a customer sees for an expired link - harmless, and still a
      // real URL on the real host, so the carrier judges it the way it
      // judges the real ones.
      result = await sendSms(
        phone,
        "WHYTE ROUTES test: if you received this, SMS with links is working. " +
        `${TRACKING_SHORT_URL}/${newTrackingToken()}\n\nReply STOP to opt out.`
      );
    } catch (err) {
      result = { accepted: false, failureReason: err.message || "SMS send threw an error." };
    }

    // Twilio refused the request outright (bad number, STOP, auth):
    // there is no message to follow, so that IS the outcome.
    if (!result.accepted) {
      console.log(
        `⚠️ test notification (company ${companyId}) -> rejected by Twilio` +
        (result.errorCode ? ` [${result.errorCode}]` : "") +
        ` (${result.failureReason})`
      );
      return {
        accepted: false,
        delivered: false,
        final: true,
        status: result.providerStatus || "rejected",
        errorCode: result.errorCode || null,
        failureReason: describeTwilioError(result.errorCode, result.failureReason) || result.failureReason,
        providerMessageId: null,
      };
    }

    // Twilio took it. Now find out what actually happened to it.
    const outcome = await waitForFinalTwilioStatus(result.providerMessageId);

    // The SID is what makes a test traceable: paste it into Twilio
    // Console > Monitor > Logs > Messaging to see the carrier's side.
    console.log(
      `${outcome.delivered ? "✅" : outcome.final ? "❌" : "⏳"} test notification ` +
      `(company ${companyId}) sid=${outcome.providerMessageId} from=${outcome.from} ` +
      `status=${outcome.status}` +
      (outcome.errorCode ? ` error=${outcome.errorCode}` : "")
    );

    // Remembered so "Check Again" can look this message up later - and
    // only messages this company sent, never an arbitrary SID.
    await admin.firestore()
      .doc(`companies/${companyId}/testNotifications/${outcome.providerMessageId}`)
      .set({
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        status: outcome.status,
        errorCode: outcome.errorCode,
      });

    return outcome;
  }
);

// "Check Again" on the test screen, for a message whose carrier
// receipt hadn't arrived inside the first 20 seconds. Read-only; sends
// nothing and costs nothing.
exports.getTestNotificationStatus = onCall(
  { secrets: [TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const sid = (request.data && request.data.sid || "").trim();
    if (!/^SM[0-9a-f]{32}$/.test(sid)) {
      throw new HttpsError("invalid-argument", "A Twilio message SID is required.");
    }
    const userSnap = await admin.firestore().doc(`users/${request.auth.uid}`).get();
    const userData = userSnap.data();
    if (!userData || !userData.companyId || userData.platformAdmin !== true) {
      throw new HttpsError("permission-denied", "Test notifications are not available on this account.");
    }
    const recordRef = admin.firestore().doc(`companies/${userData.companyId}/testNotifications/${sid}`);
    if (!(await recordRef.get()).exists) {
      throw new HttpsError("not-found", "That test message wasn't sent from this company.");
    }
    const outcome = testOutcomeFrom(sid, await fetchTwilioMessage(sid));
    await recordRef.update({ status: outcome.status, errorCode: outcome.errorCode });
    console.log(`🔎 test notification recheck sid=${sid} status=${outcome.status}` +
      (outcome.errorCode ? ` error=${outcome.errorCode}` : ""));
    return outcome;
  }
);

// sendTrackingLink
//
// For customers who'd rather not be texted at every step: one message
// with a link they can open whenever they want, instead of a stream of
// ETA and status updates. The page it points at is public but
// unguessable (hosting/track.html reads one Firestore document by its
// auto-generated id) and exposes only a position, an ETA and the
// service address - never the driver's name, phone or id.
//
// The link is created here rather than on the client so the URL that
// gets sent is always one this function actually just wrote, and so
// re-sending reuses the existing link instead of quietly orphaning the
// one the customer already has open.
const TRACKING_BASE_URL = "https://whyte-routes.web.app/track";

// SHORT, OPAQUE LINKS.
//
// The old URL was ...track?c=DW%20Landscaping&t=K4Ww4j0uhg9sZM6Eg884 -
// 78 characters, two query parameters, and the operating company's
// real business name sitting in the address bar of a page sent to
// their own customers. Both halves of that are a problem: long
// query-string URLs are a well-known carrier spam signal on exactly
// the unregistered long-code traffic these texts ride on, and the
// company id was never the customer's business to see.
//
// A token is 12 characters of crypto-random base62 - 62^12, far past
// guessing - and resolves to the company/link pair server-side. The
// URL now carries no meaning at all, which is the point.
// ON THE OWNER'S OWN DOMAIN (2026-11-18). Carriers filter *.web.app
// links from our sending number - 18 of 18 blocked (30007), with or
// without "https://" - while a link to hsbizhub.com from the same
// number was delivered. track.hsbizhub.com is a Firebase Hosting custom
// domain on this same site (CNAME -> whyte-routes.web.app), so it is
// the exact same tracking page; only the address in the text changed.
// Links already sent on whyte-routes.web.app keep working.
const TRACKING_SHORT_URL = "https://track.hsbizhub.com/t";
const TOKEN_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
function newTrackingToken() {
  const bytes = require("crypto").randomBytes(12);
  let out = "";
  for (const b of bytes) out += TOKEN_ALPHABET[b % TOKEN_ALPHABET.length];
  return out;
}

// Mints - or safely reuses - the tracking link for one stop, and
// returns the URL to text.
//
// Extracted from sendTrackingLink so that the shift-start message can
// carry a link WITHOUT a second implementation of this. The supersede
// rule below is the whole reason: it is what stops a stop that was
// re-pointed at a different customer from silently rewriting the first
// customer's open page with somebody else's name, address and live
// driver position. A parallel copy of this logic that drifted by one
// condition would be a privacy failure, not a formatting difference.
async function ensureTrackingLink({ companyId, stopId, stopData, customerName }) {
  const linksRef = admin.firestore().collection(`companies/${companyId}/trackingLinks`);
  const existing = await linksRef
    .where("stopId", "==", stopId)
    .where("active", "==", true)
    .get();

  const stopCustomerId = stopData.customerId || null;

  // Mirrors TrackingLink.belongsTo(_:) in the app - keep the two in
  // step. Fails closed in both ambiguous cases: a link written
  // before customerId existed has none recorded and so can never
  // match a stop that has one, and a one-off stop with no Customer
  // record falls back to the name and address denormalised onto the
  // link, which are byte-identical until somebody edits them.
  const belongsToStop = (linkData) => {
    const linkCustomerId = linkData.customerId || null;
    if (linkCustomerId || stopCustomerId) return linkCustomerId === stopCustomerId;
    return linkData.address === (stopData.address || "")
      && linkData.customerName === customerName;
  };

  const reusable = existing.docs.find((d) => belongsToStop(d.data()));

  // Everything active on this stop that is NOT this customer's is
  // torn down before the new link is handed out. Deliberately no
  // completedAt: the security rule keeps a link readable for two
  // hours after completion so a customer's page can show that their
  // service finished, and a superseded customer is owed no such
  // window - the page it powers is showing them somebody else's
  // name and address. active:false with no completedAt denies the
  // read immediately.
  for (const stale of existing.docs) {
    if (reusable && stale.id === reusable.id) continue;
    await stale.ref.collection("location").doc("current").delete().catch(() => {});
    await stale.ref.set({
      active: false,
      superseded: true,
      supersededAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }

  let linkId;
  if (reusable) {
    linkId = reusable.id;
    // Refresh the denormalised copy before re-sending. These fields
    // were a snapshot of the stop at creation time and the document
    // was reused verbatim, so a corrected address left the re-sent
    // link still drawing the map pin at the old one.
    await linksRef.doc(linkId).set({
      customerName,
      address: stopData.address || "",
      ...(stopCustomerId ? { customerId: stopCustomerId } : {}),
      ...(typeof stopData.latitude === "number" ? { stopLatitude: stopData.latitude } : {}),
      ...(typeof stopData.longitude === "number" ? { stopLongitude: stopData.longitude } : {}),
    }, { merge: true });
  } else {
    const doc = linksRef.doc();
    await doc.set({
      customerName,
      address: stopData.address || "",
      stopId,
      // WHO this link is for, so nothing downstream has to infer it
      // from the stop. Safe on a world-readable document in a way
      // driverId was not: it identifies the person holding the link
      // rather than a third party, and the customers collection
      // stays unreadable without a login either way.
      ...(stopCustomerId ? { customerId: stopCustomerId } : {}),
      // driverId and routeId are deliberately NOT written here.
      // This document is world-readable to anyone holding the link,
      // and an adversarial review flagged both as internal
      // identifiers published unauthenticated for no functional
      // reason - the page never reads them.
      active: true,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(typeof stopData.latitude === "number" ? { stopLatitude: stopData.latitude } : {}),
      ...(typeof stopData.longitude === "number" ? { stopLongitude: stopData.longitude } : {}),
    });
    linkId = doc.id;
  }

  // ENCODED. Both of these go into a query string that is then sent
  // as an SMS, and a company id is not guaranteed to be URL-safe:
  // companies created before ids were auto-generated have
  // human-readable document ids, and Firestore allows spaces in
  // them. "DW Landscaping" produced
  //   ...track?c=DW Landscaping&t=K4Ww...
  // which every SMS client truncates at the space, so the customer
  // received a link that resolved to a company id of "DW" - a tenant
  // that does not exist - and a page that could never load. The link
  // had been sending successfully and arriving broken.
  // The token is stored ON the link, so re-sending reuses it and a
  // customer's existing URL keeps working rather than being orphaned -
  // the same reasoning as reusing the link document itself.
  const linkDoc = await linksRef.doc(linkId).get();
  let token = linkDoc.exists && linkDoc.data().token;
  if (!token) {
    token = newTrackingToken();
    await linksRef.doc(linkId).set({ token }, { merge: true });
  }
  // The lookup document. Deliberately holds nothing but the pointer -
  // no name, no address, no coordinates - so the token resolves the
  // link without becoming a second copy of the customer's data.
  await admin.firestore().doc(`trackingTokens/${token}`).set({
    companyId,
    linkId,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  const url = `${TRACKING_SHORT_URL}/${token}`;
  return { linkId, url, token };
}

exports.sendTrackingLink = onCall(
  // RESEND_API_KEY was missing here, so the email branch below could
  // never read the key and every emailed tracking link failed.
  { secrets: [TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER, RESEND_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }

    const { routeId, stopId } = request.data || {};
    if (!routeId || !stopId) {
      throw new HttpsError("invalid-argument", "routeId and stopId are required.");
    }

    const uid = request.auth.uid;
    const userSnap = await admin.firestore().doc(`users/${uid}`).get();
    const userData = userSnap.data();
    if (!userData || !userData.companyId) {
      throw new HttpsError("failed-precondition", "No company associated with this account.");
    }
    const companyId = userData.companyId;

    const companySnap = await admin.firestore().doc(`companies/${companyId}`).get();
    const companyData = companySnap.data();
    if (!companyData) {
      throw new HttpsError("failed-precondition", "Company not found.");
    }
    if (tierRank(companyData.subscriptionTier) < 1) {
      return { deliveryStatus: "not_entitled" };
    }

    const stopRef = admin.firestore().doc(`companies/${companyId}/routes/${routeId}/stops/${stopId}`);
    const stopSnap = await stopRef.get();
    const stopData = stopSnap.data();
    if (!stopData) {
      throw new HttpsError("not-found", "Stop not found.");
    }

    // Same precedence as sendCustomerNotification: the linked Customer
    // record wins over the copy cached on the stop.
    let customerName = stopData.customerName || "Customer";
    let phone = stopData.customerPhone;
    let optedIn = !!stopData.customerOptedIn;
    let smsEnabled = true;
    let email = stopData.customerEmail;
    let emailEnabled = true;

    if (stopData.customerId) {
      const customerSnap = await admin.firestore().doc(`companies/${companyId}/customers/${stopData.customerId}`).get();
      const customerData = customerSnap.data();
      if (customerData) {
        customerName = customerData.name || customerName;
        phone = customerData.phone;
        email = customerData.email;
        optedIn = !!customerData.notificationsOptIn;
        smsEnabled = customerData.smsEnabled !== false;
        emailEnabled = customerData.emailEnabled !== false;
      } else {
        // Same rule as sendCustomerNotification: a deleted customer
        // record means do not contact, not "fall back to the phone
        // number cached on the stop."
        return { deliveryStatus: "customer_deleted" };
      }
    }

    // EMAIL IS A REAL CHANNEL HERE NOW, not an omission.
    //
    // This function could only ever send SMS, so a customer who keeps
    // SMS off - or who has an email address and no mobile number -
    // could never receive a tracking link at all. "Live tracking link
    // for customers" is a bullet on the Premium paywall, so that was a
    // paid feature silently unavailable to part of the customer base.
    //
    // Same precedence as every other notification in this file: SMS
    // when it is available, email otherwise. Deliberately NOT both -
    // one event should produce one message, and doubling every link
    // send would double the annoyance and the cost.
    const canSms = smsEnabled && phone && phone.trim().length > 0;
    const canEmail = emailEnabled && email && email.trim().length > 0;

    if (!optedIn) return { deliveryStatus: "not_opted_in" };
    if (!canSms && !canEmail) {
      const hasContact = (phone && phone.trim()) || (email && email.trim());
      return { deliveryStatus: hasContact ? "channel_disabled" : "no_contact_on_file" };
    }

    // Reuse an existing active link for this stop so a customer who
    // already has the page open doesn't get a URL that silently stops
    // updating when a second link supersedes it.
    //
    // Reuse is only safe for the SAME PERSON, though, and a matching
    // stopId is not proof of that. The owner's "Change Customer"
    // picker re-points a stop at somebody else and keeps stop.id, so
    // "the active link for this stop" can be a link that was minted
    // for, and texted to, a different customer entirely. Refreshing it
    // in place then rewrote that customer's open page with the new
    // customer's name, address and map pin - and left it live to
    // receive the driver's position on the way to that address.
    //
    // So: same customer, refresh in place. Different customer,
    // SUPERSEDE - the old link goes dark and a new document id is
    // minted, which is also what makes the already-sent URL stop
    // working rather than quietly changing meaning.
    const { linkId, url } = await ensureTrackingLink({
      companyId, stopId, stopData, customerName,
    });

    // "Reply STOP to opt out" is not decoration. Its absence is one of
    // the signals carriers filter application traffic on, and campaign
    // vetting requires it. Sender name per the company's choice - see
    // smsBrand. The email copy drops the SMS-only STOP line.
    const message = `${smsBrand(companyData)}: Track your service live: ${url}`;
    const smsMessage = withOptOut(message);

    // This text IS a link, so while links are carrier-blocked (see
    // smsLinksBlocked) an SMS would be billed and silently eaten. Use
    // email if the customer has it; otherwise say so plainly and point
    // the owner at Share Link, which sends from their own phone.
    let reserved = 0;
    const optedOut = canSms && (await smsOptedOut(phone));
    if (optedOut && !canEmail) {
      return { deliveryStatus: "sms_opted_out", url, linkId: null, method: "none",
        failureReason: "This customer replied STOP to our texts. They won't get texts until they reply START." };
    }
    if (canSms && !optedOut && !smsLinksBlocked()) {
      reserved = await reserveSmsSegments(companyId, companyData, withOptOut(`${smsBrand(companyData)}: Track your service live: ${url}`));
    }
    const useSms = reserved > 0;
    if (canSms && !useSms && !canEmail) {
      const capped = !smsLinksBlocked();
      console.log(`⚠️ tracking link ${linkId} (company ${companyId}) -> held (${capped ? "sms_allowance_reached" : "links_blocked"}), no email on file`);
      return {
        deliveryStatus: capped ? "sms_allowance_reached" : "blocked_links_unregistered_sender",
        url, linkId, method: "none",
        failureReason: capped
          ? "Your monthly customer text allowance is used up - texts resume on the 1st. Use Share Link (free) to send it from your own phone."
          : "Carriers are blocking texts that contain links from our current number. Use Share Link (free) to send it from your own phone.",
      };
    }

    let result;
    const method = useSms ? "sms" : "email";
    const contact = useSms ? phone : email;
    try {
      result = useSms
        ? await sendSms(phone, smsMessage, { statusPath: stopRef.collection("notifications").doc(`${stopId}_trackingLink`).path })
            .then(async (r) => {
              if (!r.accepted) await releaseSmsSegments(companyId, companyData, reserved);
              else await rememberSmsRecipient(phone, companyId);
              return r;
            })
        : await sendEmail(email, "Track your service in real time", message, smsBrand(companyData));
    } catch (err) {
      result = { accepted: false, failureReason: err.message || `${method} send threw an error.` };
    }

    const deliveryStatus = result.accepted ? "accepted" : "failed";

    // Logged alongside the other customer notifications so the owner's
    // history shows that a link was sent, not just ETA/status texts.
    await stopRef.collection("notifications").doc(`${stopId}_trackingLink`).set({
      stopId, routeId, customerName,
      type: "trackingLink",
      contactMethod: method,
      contactValue: contact,
      deliveryStatus,
      providerMessageId: result.providerMessageId || null,
      failureReason: result.failureReason || null,
      message: useSms ? smsMessage : message,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    if (result.accepted) {
      const period = new Date().toISOString().slice(0, 7);
      await admin.firestore().doc(`companies/${companyId}/notificationUsage/${period}`).set({
        [method === "sms" ? "smsCount" : "emailCount"]: admin.firestore.FieldValue.increment(1),
        [method === "sms" ? "estimatedSmsCostUsd" : "estimatedEmailCostUsd"]:
          admin.firestore.FieldValue.increment(method === "sms" ? 0.0079 : 0),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    console.log(
      `${result.accepted ? "✅" : "⚠️"} tracking link ${linkId} (company ${companyId}, ${method}) -> ${deliveryStatus}` +
      (result.failureReason ? ` (${result.failureReason})` : "")
    );

    return { deliveryStatus, url, linkId, method, failureReason: result.failureReason || null };
  }
);

// ─────────────────────────────────────────────────────────────────────
// DELETE A ROUTE - owner or manager only, everything it owns goes with it.
//
// There was no way to delete a route at all. Done client-side it would
// leave orphans: Firestore doesn't cascade, so each stop's photos and
// notification history would linger, customers' tracking links would
// stay live, and a driver whose activeRoute pointed here would keep a
// dangling pointer. This does it in one place, with admin rights:
//   1. close every still-active tracking link for the route's stops
//      (active:false with no completedAt = the page reads "no longer
//      available", which is true);
//   2. clear activeRoute on any driver pointing at this route;
//   3. recursively delete the route, its stops and their subcollections.
// Customers themselves are never touched.
// THE FREE WAY TO SEND A TRACKING LINK.
//
// Returns the customer's live tracking URL WITHOUT texting or emailing
// it, so the owner can share it from their own phone (Messages, copy,
// WhatsApp...). Nothing goes through Twilio, so it costs nothing and is
// unaffected by carrier filtering of link-carrying texts. The owner is
// messaging their own customer personally, so the app's opt-in gate
// (which governs texts the APP sends) doesn't apply; the deleted-
// customer stop still does - a removed customer gets no fresh link.
// Same link minting as sendTrackingLink, so a resend reuses the link a
// customer may already have open.
exports.getTrackingLink = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const { routeId, stopId } = request.data || {};
  if (!routeId || !stopId) {
    throw new HttpsError("invalid-argument", "routeId and stopId are required.");
  }

  const uid = request.auth.uid;
  const userSnap = await admin.firestore().doc(`users/${uid}`).get();
  const userData = userSnap.data();
  if (!userData || !userData.companyId) {
    throw new HttpsError("failed-precondition", "No company associated with this account.");
  }
  const companyId = userData.companyId;

  const companySnap = await admin.firestore().doc(`companies/${companyId}`).get();
  const companyData = companySnap.data();
  if (!companyData) {
    throw new HttpsError("failed-precondition", "Company not found.");
  }
  if (tierRank(companyData.subscriptionTier) < 1) {
    return { status: "not_entitled" };
  }

  const stopRef = admin.firestore().doc(`companies/${companyId}/routes/${routeId}/stops/${stopId}`);
  const stopSnap = await stopRef.get();
  const stopData = stopSnap.data();
  if (!stopData) {
    throw new HttpsError("not-found", "Stop not found.");
  }

  let customerName = stopData.customerName || "Customer";
  if (stopData.customerId) {
    const customerSnap = await admin.firestore().doc(`companies/${companyId}/customers/${stopData.customerId}`).get();
    const customerData = customerSnap.data();
    if (!customerData) return { status: "customer_deleted" };
    customerName = customerData.name || customerName;
  }

  const { linkId, url } = await ensureTrackingLink({
    companyId, stopId, stopData, customerName,
  });

  console.log(`🔗 tracking link ${linkId} (company ${companyId}) shared manually`);

  return {
    status: "ok",
    url,
    linkId,
    // Ready-to-send wording, matching the texted version minus the
    // STOP line (that only applies to texts the app sends).
    message: `${smsBrand(companyData)}: Track your service live: ${url}`,
  };
});

exports.deleteRoute = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const routeId = (request.data && request.data.routeId || "").trim();
  if (!routeId || routeId.includes("/")) {
    throw new HttpsError("invalid-argument", "routeId is required.");
  }

  const userSnap = await admin.firestore().doc(`users/${request.auth.uid}`).get();
  const user = userSnap.data();
  if (!user || !user.companyId) {
    throw new HttpsError("failed-precondition", "No company associated with this account.");
  }
  if (user.companyRole !== "owner" && user.companyRole !== "manager") {
    throw new HttpsError("permission-denied", "Only an owner or manager can delete routes.");
  }
  const companyId = user.companyId;
  const db = admin.firestore();
  const routeRef = db.doc(`companies/${companyId}/routes/${routeId}`);
  const routeSnap = await routeRef.get();
  if (!routeSnap.exists) {
    throw new HttpsError("not-found", "That route doesn't exist (it may already be deleted).");
  }

  const stopsSnap = await routeRef.collection("stops").get();
  const stopIds = stopsSnap.docs.map((d) => d.id);

  let linksClosed = 0;
  for (let i = 0; i < stopIds.length; i += 30) {
    const chunk = stopIds.slice(i, i + 30);
    const links = await db.collection(`companies/${companyId}/trackingLinks`)
      .where("stopId", "in", chunk)
      .where("active", "==", true)
      .get();
    for (const link of links.docs) {
      await link.ref.set({ active: false, routeDeleted: true }, { merge: true });
      linksClosed++;
    }
  }

  const pointing = await db.collection(`companies/${companyId}/drivers`)
    .where("activeRoute", "==", routeId).get();
  for (const d of pointing.docs) {
    await d.ref.update({ activeRoute: admin.firestore.FieldValue.delete() });
  }

  await db.recursiveDelete(routeRef);

  console.log(`🗑️ route ${routeId} (company ${companyId}) deleted by ${request.auth.uid}: ` +
    `${stopIds.length} stops, ${linksClosed} links closed, ${pointing.size} driver pointer(s) cleared`);
  return { deleted: true, stops: stopIds.length, linksClosed };
});

// ─────────────────────────────────────────────────────────────────────
// A STOP'S ADDRESS CHANGED -> ITS LIVE CUSTOMER LINK FOLLOWS.
//
// A tracking link keeps its own copy of the address and home-pin
// coordinates, taken when it is minted (at Start Shift, inside the
// shift-start text). On the Nov 4 drive test the owner corrected the
// stop to 157 Crosby 20 seconds after the link was minted for 802 Pam:
// the driver app and the ETA used the new address, but the customer's
// page kept drawing the old pin and line - "5 min" from Richmond Hill to
// Newmarket, and the wrong service address on screen.
//
// This runs on every stop update but only writes when the address or
// coordinates actually changed, and only to links still active for that
// stop. A completed or superseded link is left alone (it's history).
// Only the address/pin fields are touched - never the token, customer
// name or active flags that ensureTrackingLink owns.
exports.syncTrackingLinkAddress = onDocumentUpdated(
  "companies/{companyId}/routes/{routeId}/stops/{stopId}",
  async (event) => {
    const before = (event.data && event.data.before.data()) || {};
    const after = (event.data && event.data.after.data()) || {};
    if (before.address === after.address
        && before.latitude === after.latitude
        && before.longitude === after.longitude) {
      return;
    }

    const { companyId, stopId } = event.params;
    const links = await admin.firestore()
      .collection(`companies/${companyId}/trackingLinks`)
      .where("stopId", "==", stopId)
      .where("active", "==", true)
      .get();
    if (links.empty) return;

    const del = admin.firestore.FieldValue.delete();
    const update = {
      address: after.address || "",
      stopLatitude: typeof after.latitude === "number" ? after.latitude : del,
      stopLongitude: typeof after.longitude === "number" ? after.longitude : del,
    };
    await Promise.all(links.docs.map((d) => d.ref.update(update)));
    console.log(`📍 stop ${stopId} (company ${companyId}) address changed -> updated ${links.size} live tracking link(s)`);
  }
);

// ─────────────────────────────────────────────────────────────────────
// revokeEmployee - ATOMIC OFFBOARDING
//
// An owner CANNOT revoke access from the client, and this is not a
// missing button - it is structural. firestore.rules:254 freezes
// companyId on the owner-manages-employee branch, :255 restricts
// companyRole to manager|driver, :165 blocks reading another user's
// document and :357 blocks deleting it. The single field that gates
// every authorization helper is the one field the owner is forbidden
// to touch. So this runs on the Admin SDK, which bypasses rules - and
// that is precisely why it needs ZERO changes to the hardened rules
// file. The cross-tenant branch that closed a full takeover stays
// exactly as it is.
//
// THE TRAP THIS AVOIDS: deleting companies/{c}/drivers/{uid} is
// permitted for staff and revokes NOTHING - no helper reads that
// document for authorization. The driver would keep route reads, stop
// writes, photo uploads and GPS publishing. It looks like removal,
// does nothing, and orphans the payroll history behind it.
//
// ORDER MATTERS. Access is cut LAST, because two things become
// impossible the instant companyId disappears:
//   1. The open shift can never be closed by anyone. Rules let only
//      the driver write their own shifts (:438); staff get read and
//      delete but never update (:436/:439). Cut access first and
//      endedAt stays nil forever, corrupting hours already worked.
//   2. The assigned route strands. assignDriver stamps driverId onto
//      the route AND every stop, and nothing reverses it - the owner's
//      own handles go through fetchRouteForDriver(driverId:), so the
//      route would sit "assigned" to a ghost uid with no UI left to
//      reassign it. An unserviced route, mid-storm.
exports.revokeEmployee = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const targetUid = request.data && request.data.targetUid;
  if (typeof targetUid !== "string" || targetUid.length === 0) {
    throw new HttpsError("invalid-argument", "targetUid is required.");
  }

  const uid = request.auth.uid;
  if (uid === targetUid) {
    throw new HttpsError("failed-precondition", "You cannot remove yourself from your own company.");
  }

  const db = admin.firestore();

  // companyId comes from the CALLER'S OWN document, never from
  // request.data - the same rule every other callable here follows, so
  // a uid from another tenant simply is not found below.
  const callerSnap = await db.doc(`users/${uid}`).get();
  const caller = callerSnap.data();
  if (!caller || !caller.companyId) {
    throw new HttpsError("failed-precondition", "No company associated with this account.");
  }
  if (caller.companyRole !== "owner") {
    throw new HttpsError("permission-denied", "Only the company owner can remove an employee.");
  }
  const companyId = caller.companyId;

  const targetSnap = await db.doc(`users/${targetUid}`).get();
  const target = targetSnap.data();
  if (!target || target.companyId !== companyId) {
    throw new HttpsError("not-found", "That person is not in your company.");
  }

  // ---- ALL READS FIRST (a batch cannot read) ----
  const openShifts = await db
    .collection(`companies/${companyId}/drivers/${targetUid}/shifts`)
    .where("status", "==", "active")
    .get();

  const assignedRoutes = await db
    .collection(`companies/${companyId}/routes`)
    .where("driverId", "==", targetUid)
    .get();
  const liveRoutes = assignedRoutes.docs.filter((d) => d.data().status !== "completed");
  const stopsPerRoute = await Promise.all(liveRoutes.map((r) => r.ref.collection("stops").get()));
  const liveStopIds = new Set(stopsPerRoute.flatMap((s) => s.docs.map((d) => d.id)));

  // Filtered in memory rather than with a `where in` - that operator
  // caps at 10 values and a driver can hold far more stops than that.
  const activeLinks = await db
    .collection(`companies/${companyId}/trackingLinks`)
    .where("active", "==", true)
    .get();
  const linksToKill = activeLinks.docs.filter((d) => liveStopIds.has(d.data().stopId));

  const now = admin.firestore.FieldValue.serverTimestamp();

  // ---- PASS 1: release routes and stops, chunked ----
  // Firestore caps a batch at 500 writes and a driver may hold several
  // routes of 100+ stops, so this cannot be one commit. It runs first
  // and separately: a partially released route is recoverable (the
  // owner simply reassigns it), whereas a partially cut access grant
  // is not.
  let released = 0;
  for (let i = 0; i < liveRoutes.length; i++) {
    const routeDoc = liveRoutes[i];
    const stops = stopsPerRoute[i].docs;
    let batch = db.batch();
    let ops = 0;

    // Exact inverse of RouteRepository.assignDriver: route + every stop.
    batch.update(routeDoc.ref, { driverId: "", status: "pending", updatedAt: now });
    ops++;

    for (const stop of stops) {
      if (ops >= 450) {
        await batch.commit();
        batch = db.batch();
        ops = 0;
      }
      batch.update(stop.ref, { driverId: "" });
      ops++;
    }
    if (ops > 0) await batch.commit();
    released++;
  }

  // ---- PASS 2: the atomic cut ----
  // Shift close, link supersede, tombstone and access removal commit
  // together or not at all. There is no state where access is gone but
  // the shift is still open.
  const finalBatch = db.batch();

  // Payroll first. Preserve, never delete.
  openShifts.docs.forEach((d) => {
    finalBatch.update(d.ref, { endedAt: now, status: "completed", endedBy: "revoked" });
  });

  // `superseded` is excluded outright by isLiveTrackingLink; active:false
  // alone would leave the completedAt grace window open, so a customer
  // could still watch a revoked driver.
  linksToKill.forEach((d) => {
    finalBatch.update(d.ref, { active: false, superseded: true, supersededAt: now });
  });

  // TOMBSTONE, never delete. Subcollections survive parent deletion, so
  // deleting this document would leave the logged hours intact and
  // permanently unreachable - the owner's only path to payroll iterates
  // this very collection.
  finalBatch.set(
    db.doc(`companies/${companyId}/drivers/${targetUid}`),
    {
      status: "revoked",
      revokedAt: now,
      revokedBy: uid,
      activeRoute: admin.firestore.FieldValue.delete(),
      latitude: admin.firestore.FieldValue.delete(),
      longitude: admin.firestore.FieldValue.delete(),
      lastUpdated: admin.firestore.FieldValue.delete(),
    },
    { merge: true }
  );

  // THE CUT. This one field is the whole revocation, across Firestore
  // AND Storage (storage.rules re-reads this same document, so licence
  // photos and proof-of-work images die in the same write).
  //
  // FieldValue.delete(), not null: the late-invite branch tests
  // `!('companyId' in resource.data)`, so removing the KEY is what lets
  // a seasonal driver be re-hired on a fresh invite next winter.
  finalBatch.update(db.doc(`users/${targetUid}`), {
    companyId: admin.firestore.FieldValue.delete(),
    companyRole: admin.firestore.FieldValue.delete(),
    revokedFromCompanyId: companyId,
    revokedAt: now,
  });

  await finalBatch.commit();

  console.log(
    `🔒 revokeEmployee: ${targetUid} removed from ${companyId} by ${uid} ` +
    `(${released} routes released, ${openShifts.size} shifts closed, ${linksToKill.length} links superseded)`
  );

  // Deliberately NOT calling admin.auth().revokeRefreshTokens(). Rules
  // are data-driven and re-evaluated server-side on every request, so
  // the cut is already instant; revoking tokens would additionally sign
  // the person out of their own Apple/email account, which still
  // legitimately exists and is not ours to terminate.
  return {
    revoked: true,
    routesReleased: released,
    shiftsClosed: openShifts.size,
    linksSuperseded: linksToKill.length,
  };
});

// ─────────────────────────────────────────────────────────────────────
// BACKFILL SERVICE HISTORY FROM THE TEXT LOG (one storm at a time).
//
// See serviceHistoryBackfill.js for what gets rebuilt and why. This
// wrapper only reads the caller's own company and, when dryRun is
// false, writes the planned records with create() - which FAILS if the
// document already exists, so it can never overwrite a visit (live or
// recovered) and running it twice adds nothing the second time.
//
// Owner only. dryRun defaults to TRUE: the first call always just
// returns the list for a human to check.
//
// Customer names/addresses go back to the signed-in owner only; the
// function log carries ids and counts, never PII.
// ─────────────────────────────────────────────────────────────────────
const { planRecoveredVisits } = require("./serviceHistoryBackfill");

exports.backfillServiceHistoryFromLogs = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const serviceDate = String((request.data && request.data.serviceDate) || "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(serviceDate)) {
    throw new HttpsError("invalid-argument", "serviceDate must be YYYY-MM-DD.");
  }
  const dryRun = !(request.data && request.data.dryRun === false);

  const db = admin.firestore();
  const user = (await db.doc(`users/${request.auth.uid}`).get()).data();
  if (!user || !user.companyId) {
    throw new HttpsError("failed-precondition", "No company associated with this account.");
  }
  if (user.companyRole !== "owner") {
    throw new HttpsError("permission-denied", "Only the company owner can recover service history.");
  }
  const companyId = user.companyId;
  const company = (await db.doc(`companies/${companyId}`).get()).data() || {};
  const timeZone = company.timeZoneIdentifier || "America/Toronto";

  const driverNames = {};
  (await db.collection(`companies/${companyId}/drivers`).get())
    .forEach((d) => { if (d.data().name) driverNames[d.id] = d.data().name; });

  const routes = [];
  const routeSnaps = await db.collection(`companies/${companyId}/routes`).get();
  for (const r of routeSnaps.docs) {
    const stops = [];
    const stopSnaps = await r.ref.collection("stops").get();
    for (const s of stopSnaps.docs) {
      const notifs = await s.ref.collection("notifications").where("type", "==", "completed").get();
      stops.push({
        id: s.id,
        data: s.data(),
        notifications: notifs.docs.map((n) => ({ id: n.id, data: n.data() })),
      });
    }
    routes.push({ id: r.id, name: r.data().name, stops });
  }

  const plans = planRecoveredVisits({ serviceDate, timeZone, routes, driverNames });

  const results = [];
  for (const p of plans) {
    const ref = db.doc(`companies/${companyId}/serviceHistory/${p.visitId}`);
    const exists = (await ref.get()).exists;
    let status = exists ? "already_recorded" : (dryRun ? "would_create" : "created");
    if (!exists && !dryRun) {
      try {
        await ref.create({ ...p.record, createdAt: admin.firestore.FieldValue.serverTimestamp() });
      } catch (e) {
        status = e.code === 6 ? "already_recorded" : `error: ${e.message}`;
      }
    }
    results.push({ ...p.summary, status });
  }

  const created = results.filter((r) => r.status === "created").length;
  console.log(`🗂️ backfillServiceHistoryFromLogs company ${companyId} day ${serviceDate} ` +
    `dryRun=${dryRun}: ${plans.length} planned, ${created} created`);
  return { serviceDate, timeZone, dryRun, count: plans.length, created, visits: results };
});

// ─────────────────────────────────────────────────────────────────────
// TWILIO DELIVERY RESULTS -> NO SILENT FAILURES.
//
// Twilio only says "accepted" when a text is sent; whether the carrier
// delivered it, or filtered it as spam (30007), arrives seconds later.
// Before this, nothing listened: a filtered customer text sat in the log
// as "accepted" and the owner had no idea that customer never heard from
// them. Now every customer SMS carries a StatusCallback (see sendSms)
// pointing here with the path of its notification document, and:
//   delivered            -> log updated to "delivered"
//   undelivered / failed -> log updated to "undelivered" with the reason,
//                           AND an alert is raised in
//                           companies/{c}/textAlerts/{notificationId}
//                           that the owner sees in the app (which
//                           customer, which text, why), so Devon can
//                           text that customer from his own phone.
//
// Only requests carrying a valid X-Twilio-Signature (HMAC-SHA1 with our
// auth token) are accepted, and the path must be a notification document
// - nothing else in the database can be touched from here. No customer
// name or number is logged.
// ─────────────────────────────────────────────────────────────────────
const crypto = require("crypto");

const NOTIFICATION_PATH_RE = /^companies\/([^/]+)\/routes\/([^/]+)\/stops\/([^/]+)\/notifications\/([^/]+)$/;

function twilioSignatureValid(authToken, url, params, signature) {
  if (!signature) return false;
  const data = url + Object.keys(params).sort().map((k) => k + params[k]).join("");
  const expected = crypto.createHmac("sha1", authToken).update(Buffer.from(data, "utf-8")).digest("base64");
  const a = Buffer.from(expected), b = Buffer.from(signature);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function undeliveredReason(code) {
  const c = String(code || "");
  const known = {
    "30007": "The carrier blocked it as suspected spam (error 30007).",
    "30003": "The phone was off or out of service (error 30003).",
    "30005": "That number doesn't exist or isn't active (error 30005).",
    "30006": "That number is a landline or can't receive texts (error 30006).",
    "30008": "The carrier couldn't deliver it (error 30008).",
    "21610": "The customer has replied STOP to our texts (error 21610).",
    "30032": "Our sending number isn't verified yet (error 30032).",
    "30034": "Our sending number isn't registered with carriers (error 30034).",
  };
  return known[c] || (c ? `Not delivered (error ${c}).` : "Not delivered.");
}

exports.twilioStatusCallback = onRequest(
  { secrets: [TWILIO_AUTH_TOKEN], cors: false },
  async (req, res) => {
    if (req.method !== "POST") { res.status(405).send("POST only"); return; }
    const params = req.body || {};
    const qs = (req.originalUrl || req.url || "").split("?")[1] || "";
    // Twilio signs the exact URL it was given. Accept either spelling of
    // the path in case the platform rewrites it.
    const candidates = [
      `${STATUS_CALLBACK_BASE}?${qs}`,
      `${STATUS_CALLBACK_BASE}/?${qs}`,
    ];
    const sig = req.get("X-Twilio-Signature");
    const token = TWILIO_AUTH_TOKEN.value();
    if (!candidates.some((u) => twilioSignatureValid(token, u, params, sig))) {
      console.warn("✖ twilioStatusCallback: bad or missing signature - ignored");
      res.status(403).send("bad signature");
      return;
    }

    const path = String(req.query.p || "");
    const m = path.match(NOTIFICATION_PATH_RE);
    const status = String(params.MessageStatus || "");
    const sid = String(params.MessageSid || "");
    if (!m || !sid) { res.status(200).send("ignored"); return; }
    if (!["delivered", "undelivered", "failed"].includes(status)) { res.status(200).send("ok"); return; }

    const [, companyId, routeId, stopId, notificationId] = m;
    const db = admin.firestore();
    const ref = db.doc(path);
    try {
      let snap = await ref.get();
      // The callback can, rarely, beat the write that records which
      // Twilio message this log entry belongs to. Give it a moment once.
      if (snap.exists && !snap.data().providerMessageId) {
        await new Promise((r) => setTimeout(r, 3000));
        snap = await ref.get();
      }
      if (!snap.exists) { res.status(200).send("no doc"); return; }
      const n = snap.data();
      // A later send for the same stop/type/day reuses the document; a
      // late callback for the OLDER message must not overwrite it.
      if (n.providerMessageId && n.providerMessageId !== sid) { res.status(200).send("stale"); return; }

      if (status === "delivered") {
        await ref.update({
          deliveryStatus: "delivered",
          deliveredAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log(`✅ text ${sid} (company ${companyId}) delivered`);
      } else {
        const code = params.ErrorCode || null;
        const reason = undeliveredReason(code);
        await ref.update({
          deliveryStatus: "undelivered",
          providerErrorCode: code,
          failureReason: reason,
          needsFollowUp: true,
          undeliveredAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        await db.doc(`companies/${companyId}/textAlerts/${notificationId}`).set({
          routeId, stopId, notificationPath: path,
          customerName: n.customerName || "Customer",
          type: n.type || "unknown",
          phone: n.contactValue || null,
          message: n.message || null,
          errorCode: code,
          reason,
          messageSid: sid,
          resolved: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log(`⚠️ text ${sid} (company ${companyId}, ${n.type}) ${status} [${code}] -> owner alert raised`);
      }
      res.status(200).send("ok");
    } catch (err) {
      console.error("✖ twilioStatusCallback failed:", err);
      // 500 makes Twilio retry the callback later.
      res.status(500).send("error");
    }
  }
);

// ─────────────────────────────────────────────────────────────────────
// INCOMING REPLIES: STOP / START / HELP
//
// Twilio posts every text a customer sends to our number here (set as
// the number's "A message comes in" webhook). Twilio's own default
// opt-out handling still runs alongside this: it blocks a STOPped number
// at the carrier and sends its standard STOP/START confirmations. This
// endpoint adds what the app needs:
//   STOP words  -> smsOptOuts/{phone} active, with a timestamp and a
//                  history entry; every customer-text path checks it.
//   START words -> clears it and records a fresh consent timestamp.
//   HELP words  -> a reply naming the business that last texted this
//                  phone (business name only if it has no contact info).
// No reply is sent to STOP or START (Twilio already confirms those), so
// customers never get two confirmations. Signature-checked; anything
// else a customer texts is ignored. No phone number is logged.
// ─────────────────────────────────────────────────────────────────────
const STOP_WORDS = ["STOP", "STOPALL", "STOP ALL", "UNSUBSCRIBE", "CANCEL", "END", "QUIT", "OPTOUT", "OPT OUT", "REVOKE"];
const START_WORDS = ["START", "YES", "UNSTOP"];
const HELP_WORDS = ["HELP", "INFO"];
const INBOUND_URL = "https://us-central1-whyte-routes.cloudfunctions.net/twilioInbound";

function classifyKeyword(body) {
  const w = String(body || "").trim().toUpperCase().replace(/[^A-Z ]/g, "").replace(/\s+/g, " ");
  if (STOP_WORDS.includes(w)) return "stop";
  if (START_WORDS.includes(w)) return "start";
  if (HELP_WORDS.includes(w)) return "help";
  return null;
}

function xmlEscape(t) {
  return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

async function helpReplyFor(e164) {
  const db = admin.firestore();
  const rec = (await db.doc(`smsRecipients/${e164}`).get()).data();
  const company = rec && rec.companyId ? (await db.doc(`companies/${rec.companyId}`).get()).data() : null;
  const brand = company ? smsBrand(company) : PRODUCT_SMS_BRAND;
  const contact = company && (company.contactPhone || company.contactEmail);
  return `${brand}: Service updates about your property. Msg frequency varies. Msg & data rates may apply. ` +
    (contact ? `Questions: ${contact}. ` : "") + "Reply STOP to opt out.";
}

exports.twilioInbound = onRequest(
  { secrets: [TWILIO_AUTH_TOKEN], cors: false },
  async (req, res) => {
    if (req.method !== "POST") { res.status(405).send("POST only"); return; }
    const params = req.body || {};
    const sig = req.get("X-Twilio-Signature");
    if (!twilioSignatureValid(TWILIO_AUTH_TOKEN.value(), INBOUND_URL, params, sig)) {
      console.warn("✖ twilioInbound: bad or missing signature - ignored");
      res.status(403).send("bad signature");
      return;
    }
    const e164 = toE164(params.From || "");
    const kind = classifyKeyword(params.Body);
    const empty = '<?xml version="1.0" encoding="UTF-8"?><Response></Response>';
    res.set("Content-Type", "text/xml");
    if (!e164 || !kind) { res.status(200).send(empty); return; }

    const ref = admin.firestore().doc(`smsOptOuts/${e164}`);
    const now = admin.firestore.FieldValue.serverTimestamp();
    try {
      if (kind === "stop") {
        await ref.set({ active: true, optedOutAt: now, lastKeyword: "STOP",
          history: admin.firestore.FieldValue.arrayUnion({ event: "stop", at: new Date().toISOString() }) }, { merge: true });
        console.log("🚫 twilioInbound: opt-out recorded");
        res.status(200).send(empty);
      } else if (kind === "start") {
        await ref.set({ active: false, optedInAt: now, consentRestoredAt: now, lastKeyword: "START",
          history: admin.firestore.FieldValue.arrayUnion({ event: "start", at: new Date().toISOString() }) }, { merge: true });
        console.log("✅ twilioInbound: opt-in restored");
        res.status(200).send(empty);
      } else {
        const reply = await helpReplyFor(e164);
        console.log("ℹ️ twilioInbound: HELP reply sent");
        res.status(200).send(`<?xml version="1.0" encoding="UTF-8"?><Response><Message>${xmlEscape(reply)}</Message></Response>`);
      }
    } catch (err) {
      console.error("✖ twilioInbound failed:", err);
      res.status(500).send(empty);
    }
  }
);
