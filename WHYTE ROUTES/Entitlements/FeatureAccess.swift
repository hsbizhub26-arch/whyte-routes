import Foundation

struct FeatureAccess {

    // MARK: - Premium+ Exclusive
    static func canUseLiveDriverTracking() -> Bool {
        AppEntitlements.shared.premiumPlusUnlocked
    }

    static func canAssignDrivers() -> Bool {
        AppEntitlements.shared.premiumPlusUnlocked
    }

    static func canUseMultiDriverView() -> Bool {
        AppEntitlements.shared.premiumPlusUnlocked
    }

    static func canAccessManagerDashboard() -> Bool {
        AppEntitlements.shared.premiumPlusUnlocked
    }

    // MARK: - Premium or Premium+
    static func canUseRouteOptimization() -> Bool {
        AppEntitlements.shared.premiumUnlocked ||
        AppEntitlements.shared.premiumPlusUnlocked
    }

    static func canUseAnalytics() -> Bool {
        AppEntitlements.shared.premiumUnlocked ||
        AppEntitlements.shared.premiumPlusUnlocked
    }

    // MARK: - Free Tier
    static func canViewSingleRoute() -> Bool { true }
    static func canViewDriverSchedule() -> Bool { true }
}
