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

    // Defaults false - nothing about notification timing changes for
    // a company until its owner explicitly opts in. When true, the
    // Cloud Function (not this app) suppresses live ETA/status texts
    // and queues "completed" ones between quietHoursStart and
    // quietHoursEnd in timeZoneIdentifier, batching them into one
    // morning-summary text per customer instead. See
    // sendCustomerNotification/sendMorningSummaries in functions/index.js -
    // the driver's own workflow (tap the same status buttons) never
    // changes either way.
    var quietHoursEnabled: Bool = false
    var timeZoneIdentifier: String = "America/Toronto"
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
        self.quietHoursEnabled = dict["quietHoursEnabled"] as? Bool ?? false
        self.timeZoneIdentifier = dict["timeZoneIdentifier"] as? String ?? "America/Toronto"

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
            "navigationSettings": navigationSettings.toDict(),
            "quietHoursEnabled": quietHoursEnabled,
            "timeZoneIdentifier": timeZoneIdentifier
        ]
    }

    var isActive: Bool {
        subscriptionStatus == "active" || subscriptionStatus == "beta" || subscriptionStatus == "trialing"
    }
}
