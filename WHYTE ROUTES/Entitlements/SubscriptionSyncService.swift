import Foundation
import FirebaseFirestore

final class SubscriptionSyncService {

    private let db = Firestore.firestore()

    func syncEntitlements(uid: String) async {
        do {
            let snapshot = try await db.collection("entitlements").document(uid).getDocument()

            let plus = snapshot.data()?["premiumPlus"] as? Bool ?? false
            let premium = snapshot.data()?["premium"] as? Bool ?? false

            AppEntitlements.shared.setPremiumPlus(
                unlocked: plus,
                source: EntitlementSource.sync.rawValue
            )

            AppEntitlements.shared.setPremium(
                unlocked: premium,
                source: EntitlementSource.sync.rawValue
            )

            LocalEntitlementStore.save(
                Date().timeIntervalSince1970,
                forKey: EntitlementKeys.lastSync
            )

        } catch {
            print("❌ Failed to sync entitlements: \(error)")
        }
    }
}
