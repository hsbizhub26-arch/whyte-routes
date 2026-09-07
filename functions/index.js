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

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const { SignedDataVerifier, Environment } = require("@apple/app-store-server-library");
const fs = require("fs");
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
  if (payload.revocationDate) {
    console.log(`Transaction ${payload.transactionId} was revoked - not granting access.`);
    return { granted: false, reason: "revoked" };
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
// "WHYTE ROUTES" IS LITERAL HERE, AND DELIBERATELY SO.
//
// It is not a placeholder for the tenant's company name and must not
// be turned into one. WHYTE ROUTES is the product sending the message;
// the company operating the route is a separate, independently owned
// business, and interpolating its name here would put words in that
// business's mouth to its own customers. If white-labelling is ever
// wanted it will be asked for explicitly - until then, no substitution.
const MESSAGE_TEMPLATES = {
  shiftStart: (c) =>
    `Hi ${c.customerName}, your driver has started their route today! Track live progress here: ${c.trackingUrl}`,
  eta10: (c) =>
    `Hi ${c.customerName}, your driver is approximately 10 minutes away from ${c.address}!`,
  // A RECEIPT, not just an announcement. The date and time are what
  // make it worth keeping: a customer asking "did they even come on
  // Tuesday?" has the answer in their own message history, and so does
  // the company if it is ever disputed. Stamped in the COMPANY's
  // timezone, not the Cloud Function's - see completedStamp below.
  completed: (c) =>
    `Hi ${c.customerName}, your service at ${c.address} was completed ${c.completedStamp}. Thank you!`,
};

function buildMessage(type, ctx) {
  const template = MESSAGE_TEMPLATES[type];
  if (!template) return `${ctx.companyName}: update on your service.`;
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

function buildMorningSummaryMessage(companyName, completedAtDate, timeZone) {
  const time = completedAtDate.toLocaleTimeString("en-CA", { hour: "numeric", minute: "2-digit", timeZone });
  return `${companyName} cleared your driveway last night at ${time}.`;
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
const LIVE_ONLY_TYPES = { eta10: true, shiftStart: true };

// Sends every queued morning-summary receipt for one company right
// now. Called two ways: inline, the instant any live-hours call comes
// in (so the very first "Completed" tap after 6 AM flushes the whole
// overnight queue immediately, not on a timer) - and from the 6 AM
// scheduled function itself, as the safety net for a shift that ends
// before anyone taps anything after Quiet Hours lifts.
async function flushQueuedMorningSummaries(companyId) {
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

    if (q.smsEnabled && q.phone) {
      method = "sms";
      contact = q.phone;
      try {
        result = await sendSms(q.phone, q.message);
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

async function sendSms(to, body) {
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
    return { accepted: false, providerStatus: result.status || "error", failureReason: result.message || "Twilio request failed" };
  }
  // Twilio accepts the request synchronously (status "queued"/"sending") -
  // actual carrier delivery confirmation needs a status callback
  // webhook, not built yet. "accepted" here means Twilio took the
  // message, not that it has landed on the customer's phone.
  return { accepted: true, providerStatus: result.status, providerMessageId: result.sid };
}

async function sendEmail(to, subject, body) {
  const apiKey = RESEND_API_KEY.value();

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: "WHYTE ROUTES <updates@whyte-routes.web.app>",
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
async function notifyStop({ companyId, companyData, routeId, stopId, type }) {
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
      return { deliveryStatus: "gps_stale", notificationId: null };
    }
  }

  // shiftStart has no individual toggle: a customer who is opted in
  // at all wants to know the crew is coming, and it is the message
  // that carries their tracking link.
  const typePreferenceOk = type === "eta10" ? notifyEta
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
  const shouldSend = await admin.firestore().runTransaction(async (tx) => {
    const existing = await tx.get(notificationRef);
    if (existing.exists) return false;
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

  if (!optedIn) {
    await notificationRef.update({ deliveryStatus: "not_opted_in" });
    return { deliveryStatus: "not_opted_in", notificationId };
  }

  if (!typePreferenceOk) {
    await notificationRef.update({ deliveryStatus: "type_disabled" });
    return { deliveryStatus: "type_disabled", notificationId };
  }

  const companyName = companyData.name || "Your service crew";

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
  if (type === "shiftStart") {
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

  const message = buildMessage(type, {
    companyName,
    customerName,
    address: stopData.address || "your address",
    trackingUrl,
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
    const summaryMessage = buildMorningSummaryMessage(companyName, new Date(), timeZone);
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

  if (smsEnabled && phone && phone.trim().length > 0) {
    method = "sms";
    contact = phone;
    try {
      result = await sendSms(phone, message);
    } catch (err) {
      result = { accepted: false, failureReason: err.message || "SMS send threw an error." };
    }
  } else if (emailEnabled && email && email.trim().length > 0) {
    method = "email";
    contact = email;
    try {
      result = await sendEmail(email, `Update on your service`, message);
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
    message,
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

    const openStops = stopsSnap.docs.filter((d) => {
      const data = d.data();
      return !data.isCompleted && !data.isSkipped;
    });

    let sent = 0;
    const statuses = {};
    for (const stopDoc of openStops) {
      let outcome;
      try {
        const res = await notifyStop({
          companyId, companyData, routeId, stopId: stopDoc.id, type: "shiftStart",
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

    const today = new Date().toISOString().slice(0, 10);
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

    console.log(
      `${result.accepted ? "✅" : "⚠️"} test notification (company ${companyId}) -> ` +
      `${result.accepted ? "accepted" : "failed"}` +
      (result.failureReason ? ` (${result.failureReason})` : "")
    );

    return {
      accepted: result.accepted,
      failureReason: result.failureReason || null,
      providerMessageId: result.providerMessageId || null,
    };
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
const TRACKING_SHORT_URL = "https://whyte-routes.web.app/t";
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
  { secrets: [TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER] },
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

    const companyName = companyData.name || "Your service crew";
    // "Reply STOP to opt out" is not decoration. Its absence is one of
    // the signals carriers filter application traffic on, and campaign
    // vetting requires it. Both messages that carry a link now say it.
    const message =
      `${companyName}: track your service in real time here - ${url}\n\nReply STOP to opt out.`;

    let result;
    const method = canSms ? "sms" : "email";
    const contact = canSms ? phone : email;
    try {
      result = canSms
        ? await sendSms(phone, message)
        : await sendEmail(email, "Track your service in real time", message);
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
      message,
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
