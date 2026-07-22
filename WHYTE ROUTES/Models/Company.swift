import Foundation
import FirebaseFirestore

/// A subscribing business (tenant) on the WHYTE ROUTES platform.
/// Every business record (drivers, customers, routes, etc.) lives
/// under companies/{id}/... - this document is that tenant's root.
struct Company: Identifiable {

    var id: String
    var name: String
    var ownerUID: String

    /// "free" | "starter" | "professional" | "premiumPlus" | "enterprise"
    var subscriptionTier: String

    /// "beta" | "trialing" | "active" | "cancelled"
    var subscriptionStatus: String

    /// When false, this company is never prompted for payment or
    /// expired - used for comped/beta accounts. Purely data-driven;
    /// no company name is ever special-cased in app logic.
    var billingRequired: Bool

    var createdAt: Date

    var navigationSettings: NavigationSettings = NavigationSettings()
}

extension Company {

    init?(from dict: [String: Any], id: String) {
        guard let name = dict["name"] as? String,
              let ownerUID = dict["ownerUID"] as? String else {
            return nil
        }

        self.id = id
        self.name = name
        self.ownerUID = ownerUID
        self.subscriptionTier = dict["subscriptionTier"] as? String ?? "free"
        self.subscriptionStatus = dict["subscriptionStatus"] as? String ?? "trialing"
        self.billingRequired = dict["billingRequired"] as? Bool ?? true
        self.navigationSettings = NavigationSettings(from: dict["navigationSettings"] as? [String: Any])

        if let ts = dict["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = Date()
        }
    }

    func toDict() -> [String: Any] {
        [
            "name": name,
            "ownerUID": ownerUID,
            "subscriptionTier": subscriptionTier,
            "subscriptionStatus": subscriptionStatus,
            "billingRequired": billingRequired,
            "createdAt": Timestamp(date: createdAt),
            "navigationSettings": navigationSettings.toDict()
        ]
    }

    var isActive: Bool {
        subscriptionStatus == "active" || subscriptionStatus == "beta" || subscriptionStatus == "trialing"
    }
}
