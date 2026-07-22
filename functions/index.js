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
const admin = require("firebase-admin");
const { SignedDataVerifier, Environment } = require("@apple/app-store-server-library");
const fs = require("fs");
const path = require("path");

admin.initializeApp();

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

let cachedVerifier = null;
function getVerifier() {
  if (!cachedVerifier) {
    const certPath = path.join(__dirname, "certs", "AppleRootCA-G3.cer");
    const rootCert = fs.readFileSync(certPath);
    // FUNCTIONS_EMULATOR is set automatically when running under the
    // local emulator - lets local testing verify against Sandbox
    // transactions instead of rejecting them as wrong-environment.
    const environment = process.env.FUNCTIONS_EMULATOR
      ? Environment.SANDBOX
      : Environment.PRODUCTION;
    cachedVerifier = new SignedDataVerifier(
      [rootCert],
      true, // enableOnlineChecks - also confirms revocation status with Apple, not just signature validity
      environment,
      BUNDLE_ID,
      APP_APPLE_ID
    );
  }
  return cachedVerifier;
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
    payload = await getVerifier().verifyAndDecodeTransaction(jws);
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
