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
const PRODUCT_TO_TIER = {
  "whyteroutes.premium.monthly.v2": "professional",
  "whyteroutes.premium.yearly.v2": "professional",
  "whyteroutes.premiumplus.monthly.v2": "premiumPlus",
  "whyteroutes.premiumplus.yearly.v2": "premiumPlus",
};

// A SignedDataVerifier is locked to one Apple environment at
// construction time, but this one deployed function has to accept
// transactions from whichever environment the calling build actually
// ran in - Xcode local StoreKit testing (its own local certificate,
// not real Apple ones) during development, Sandbox once builds go out
// via TestFlight, and eventually Production. Rather than guess, try
// verifying against all three and use whichever one actually
// succeeds - the JWS itself can only ever validate against the one
// environment that really signed it, so this is safe, not permissive.
const VERIFIER_ENVIRONMENTS = [Environment.PRODUCTION, Environment.SANDBOX, Environment.XCODE];
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

function buildMessage(type, companyName) {
  const time = new Date().toLocaleTimeString("en-CA", { hour: "numeric", minute: "2-digit" });
  const template = MESSAGE_TEMPLATES[type];
  if (!template) return `${companyName}: update on your service.`;
  return template(companyName, time);
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

    const stopRef = admin.firestore().doc(`companies/${companyId}/routes/${routeId}/stops/${stopId}`);
    const stopSnap = await stopRef.get();
    const stopData = stopSnap.data();
    if (!stopData) {
      throw new HttpsError("not-found", "Stop not found.");
    }

    // Freshest contact info: the linked Customer record when one
    // exists, same precedence the client already used for the
    // logging-only path this replaces.
    let customerName = stopData.customerName || "Customer";
    let phone = stopData.customerPhone;
    let email = stopData.customerEmail;
    let optedIn = !!stopData.customerOptedIn;

    if (stopData.customerId) {
      const customerSnap = await admin.firestore().doc(`companies/${companyId}/customers/${stopData.customerId}`).get();
      const customerData = customerSnap.data();
      if (customerData) {
        customerName = customerData.name || customerName;
        phone = customerData.phone;
        email = customerData.email;
        optedIn = !!customerData.notificationsOptIn;
      }
    }

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

    const companyName = companyData.name || "Your service crew";
    const message = buildMessage(type, companyName);

    let method = "none";
    let contact = null;
    let result = { accepted: false, failureReason: "No contact information on file." };

    if (phone && phone.trim().length > 0) {
      method = "sms";
      contact = phone;
      try {
        result = await sendSms(phone, message);
      } catch (err) {
        result = { accepted: false, failureReason: err.message || "SMS send threw an error." };
      }
    } else if (email && email.trim().length > 0) {
      method = "email";
      contact = email;
      try {
        result = await sendEmail(email, `Update on your service`, message);
      } catch (err) {
        result = { accepted: false, failureReason: err.message || "Email send threw an error." };
      }
    }

    const deliveryStatus = method === "none" ? "no_contact_on_file" : (result.accepted ? "accepted" : "failed");

    await notificationRef.update({
      contactMethod: method,
      contactValue: contact || "",
      deliveryStatus,
      providerMessageId: result.providerMessageId || null,
      failureReason: result.failureReason || null,
      message,
    });

    console.log(
      `${deliveryStatus === "accepted" ? "✅" : "⚠️"} notification ${notificationId} ` +
      `(company ${companyId}, ${method}) -> ${deliveryStatus}` +
      (result.failureReason ? ` (${result.failureReason})` : "")
    );

    return { deliveryStatus, notificationId };
  }
);
