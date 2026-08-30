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

const MESSAGE_TEMPLATES = {
  eta15: (companyName) => `${companyName} is about 15 minutes away.`,
  eta10: (companyName) => `${companyName} is about 10 minutes away.`,
  enRoute: (companyName) => `${companyName} is on the way.`,
  arrived: (companyName, time) => `Your service team has arrived at ${time}.`,
  completed: (companyName, time) => `Your service has been completed at ${time}.`,
};

// Real, previously-unnoticed bug fixed here: without an explicit
// timeZone, Node formats using the Cloud Function's own runtime
// timezone (UTC), so a customer would have seen "arrived at 7:15 AM"
// for an actual 3:15 AM Eastern arrival. Every caller now passes the
// company's own timeZoneIdentifier through.
function buildMessage(type, companyName, timeZone) {
  const time = new Date().toLocaleTimeString("en-CA", { hour: "numeric", minute: "2-digit", timeZone });
  const template = MESSAGE_TEMPLATES[type];
  if (!template) return `${companyName}: update on your service.`;
  return template(companyName, time);
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

// The types that are purely "driver is nearby right now" pings - not
// meaningful to a customer who's asleep, and not meaningful to queue
// for later either (by 6 AM the driver's long past that stop). These
// are simply skipped during Quiet Hours, same as not_entitled -
// nothing is written, nothing is queued.
const LIVE_ONLY_TYPES = { eta15: true, eta10: true, enRoute: true, arrived: true };

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
      await admin.firestore().doc(q.notificationRefPath).update({
        contactMethod: method,
        contactValue: contact || "",
        deliveryStatus,
        providerMessageId: result.providerMessageId || null,
        failureReason: result.failureReason || null,
      });
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

    await doc.ref.delete();
  }
}

async function sendSms(to, body) {
  const accountSid = TWILIO_ACCOUNT_SID.value();
  const authToken = TWILIO_AUTH_TOKEN.value();
  const from = TWILIO_PHONE_NUMBER.value();

  const auth = Buffer.from(`${accountSid}:${authToken}`).toString("base64");
  const params = new URLSearchParams({ To: to, From: from, Body: body });

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

    const timeZone = companyData.timeZoneIdentifier || "America/Toronto";
    const quietHours = isQuietHours(companyData);

    // The moment a call comes in outside Quiet Hours, flush whatever's
    // waiting in the overnight queue - this is what makes the very
    // first "Completed" tap after 6 AM instantly release last night's
    // batch, rather than customers waiting on the 6 AM cron.
    if (!quietHours) {
      await flushQueuedMorningSummaries(companyId);
    }

    // Live-only pings (ETA/en route/arrived) mean nothing to a
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
    let notifyEta15 = true;
    let notifyEta10 = true;
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
        notifyEta15 = customerData.notifyEta15 !== false;
        notifyEta10 = customerData.notifyEta10 !== false;
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
    // not enough on its own). enRoute/arrived/completed are driver
    // button-presses, not location-derived, so they're exempt.
    const GPS_TYPES = { eta15: true, eta10: true };
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

    const typePreferenceOk = type === "eta15" ? notifyEta15
      : type === "eta10" ? notifyEta10
      : type === "completed" ? notifyCompleted
      : true; // enRoute/arrived have no individual toggle yet

    const notificationId = `${stopId}_${type}`;
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
    const message = buildMessage(type, companyName, timeZone);

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
      result = await sendSms(phone, "This is a test notification from WHYTE ROUTES. If you received this, real SMS sending is working.");
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

    if (stopData.customerId) {
      const customerSnap = await admin.firestore().doc(`companies/${companyId}/customers/${stopData.customerId}`).get();
      const customerData = customerSnap.data();
      if (customerData) {
        customerName = customerData.name || customerName;
        phone = customerData.phone;
        optedIn = !!customerData.notificationsOptIn;
        smsEnabled = customerData.smsEnabled !== false;
      } else {
        // Same rule as sendCustomerNotification: a deleted customer
        // record means do not contact, not "fall back to the phone
        // number cached on the stop."
        return { deliveryStatus: "customer_deleted" };
      }
    }

    if (!optedIn) return { deliveryStatus: "not_opted_in" };
    if (!smsEnabled) return { deliveryStatus: "channel_disabled" };
    if (!phone || !phone.trim()) return { deliveryStatus: "no_contact_on_file" };

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
    const url = `${TRACKING_BASE_URL}?c=${encodeURIComponent(companyId)}&t=${encodeURIComponent(linkId)}`;
    const companyName = companyData.name || "Your service crew";
    const message = `${companyName}: track your service in real time here - ${url}`;

    let result;
    try {
      result = await sendSms(phone, message);
    } catch (err) {
      result = { accepted: false, failureReason: err.message || "SMS send threw an error." };
    }

    const deliveryStatus = result.accepted ? "accepted" : "failed";

    // Logged alongside the other customer notifications so the owner's
    // history shows that a link was sent, not just ETA/status texts.
    await stopRef.collection("notifications").doc(`${stopId}_trackingLink`).set({
      stopId, routeId, customerName,
      type: "trackingLink",
      contactMethod: "sms",
      contactValue: phone,
      deliveryStatus,
      providerMessageId: result.providerMessageId || null,
      failureReason: result.failureReason || null,
      message,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    if (result.accepted) {
      const period = new Date().toISOString().slice(0, 7);
      await admin.firestore().doc(`companies/${companyId}/notificationUsage/${period}`).set({
        smsCount: admin.firestore.FieldValue.increment(1),
        estimatedSmsCostUsd: admin.firestore.FieldValue.increment(0.0079),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    console.log(
      `${result.accepted ? "✅" : "⚠️"} tracking link ${linkId} (company ${companyId}) -> ${deliveryStatus}` +
      (result.failureReason ? ` (${result.failureReason})` : "")
    );

    return { deliveryStatus, url, linkId, failureReason: result.failureReason || null };
  }
);
