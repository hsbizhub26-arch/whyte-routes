const functions = require("firebase-functions");
const admin = require("firebase-admin");
const stripe = require("stripe")("YOUR_STRIPE_SECRET_KEY");
admin.initializeApp();

exports.stripeWebhook = functions.https.onRequest(async (req, res) => {
    const sig = req.headers["stripe-signature"];
    
    let event;

    try {
        event = stripe.webhooks.constructEvent(
            req.rawBody,
            sig,
            "YOUR_STRIPE_WEBHOOK_SECRET"
        );
    } catch (err) {
        return res.status(400).send(`Webhook error: ${err.message}`);
    }

    const data = event.data.object;

    if (event.type === "invoice.payment_succeeded") {
        await admin.firestore().collection("subscriptions")
            .doc(data.customer)
            .set({
                platform: "STRIPE",
                stripePriceId: data.lines.data[0].price.id,
                expiresAt: data.lines.data[0].period.end,
                status: "active"
            }, { merge: true });
    }

    if (event.type === "customer.subscription.deleted") {
        await admin.firestore().collection("subscriptions")
            .doc(data.customer)
            .set({ status: "canceled" }, { merge: true });
    }

    res.json({ received: true });
});
func isUserSubscribed() async -> Bool {
    let uid = Auth.auth().currentUser!.uid
    let doc = try? await Firestore.firestore().collection("subscriptions").document(uid).getDocument()
    
    if let data = doc?.data(),
       let expires = data["expiresAt"] as? Int {
        return Date().timeIntervalSince1970 < Double(expires)
    }
    return false
}
