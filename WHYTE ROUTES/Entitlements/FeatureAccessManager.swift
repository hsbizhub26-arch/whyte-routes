import Foundation
import Combine

// Central authority for what a company's subscription tier allows.
// Per explicit instruction: screens query this, never
// CompanySession.currentCompany?.subscriptionTier directly - one
// place to change a limit or add a gate, not scattered checks.
//
// Replaces two older, unused, never-compiled files (Entitlements/
// FeatureAccess.swift, UserPermissions.swift) that gated on an
// individual AppEntitlements flag, not the company's own tier -
// wrong model for a multi-tenant company, and confirmed zero
// call sites before removing them.
enum SubscriptionTier: Int, Comparable {
    case starter = 0
    case premium = 1
    case premiumPlus = 2
    case enterprise = 3

    // Company.subscriptionTier's raw Firestore values predate this
    // naming ("professional", not "premium") - this is the one place
    // that mapping happens, so nowhere else needs to know about it.
    static func from(_ raw: String?) -> SubscriptionTier {
        switch raw {
        case "professional": return .premium
        case "premiumPlus": return .premiumPlus
        case "enterprise": return .enterprise
        default: return .starter // "starter", "free", nil, or unrecognized
        }
    }

    static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .starter: return "Starter"
        case .premium: return "Premium"
        case .premiumPlus: return "Premium Plus"
        case .enterprise: return "Enterprise"
        }
    }
}

@MainActor
final class FeatureAccessManager: ObservableObject {

    static let shared = FeatureAccessManager()
    // nonisolated because init() itself touches no actor-isolated
    // state (empty body) - this is what actually lets a MainActor
    // class have a static-let singleton evaluated at global-init time
    // (a nonisolated context). nonisolated(unsafe) on the property
    // instead does NOT fix this: it only suppresses Sendable/data-race
    // checking on later access, it doesn't authorize calling a
    // MainActor-isolated initializer from a nonisolated context in
    // the first place - that combination is a hard compile error.
    private nonisolated init() {}

    var tier: SubscriptionTier {
        SubscriptionTier.from(CompanySession.shared.currentCompany?.subscriptionTier)
    }

    // MARK: - Customers (the one limit with an explicit number per tier)

    private static let customerLimits: [SubscriptionTier: Int] = [
        .starter: 10,
        .premium: 30
        // premiumPlus/enterprise intentionally absent - unlimited
    ]

    var customerLimit: Int? {
        Self.customerLimits[tier]
    }

    func remainingCustomerSlots(currentCount: Int) -> Int? {
        guard let limit = customerLimit else { return nil } // unlimited
        return max(0, limit - currentCount)
    }

    func canAddCustomer(currentCount: Int) -> Bool {
        guard let limit = customerLimit else { return true }
        return currentCount < limit
    }

    // MARK: - Feature gates (per the original tier spec)

    func canAccessLiveFleetMap() -> Bool { tier >= .premium }
    func canAccessProofOfWork() -> Bool { tier >= .premium }
    func canAccessDriverPerformanceReports() -> Bool { tier >= .premiumPlus }
    func canAccessPayroll() -> Bool { tier >= .premiumPlus }
    func canAccessAdvancedDispatch() -> Bool { tier >= .premiumPlus }
    // Separate from advanced dispatch on purpose. The Premium paywall
    // sells "Route optimization" by name, and Optimize Route was gated
    // on canAccessAdvancedDispatch() - so a Premium subscriber tapped
    // the feature they had just bought and got an upsell for the tier
    // above. Multi-driver dispatch stays Premium Plus; reordering one
    // route's stops is what Premium is being paid for.
    func canAccessRouteOptimization() -> Bool { tier >= .premium }

    // No per-tier route-COUNT limit was ever specified (only customer
    // counts had numbers - "unlimited routes" is only ever mentioned
    // for Premium Plus, with no ceiling given for the others). Always
    // true today; kept as part of the interface so a real limit can
    // be added here later without touching call sites.
    func canCreateAnotherRoute() -> Bool { true }

    var requiredTierForProofOfWork: SubscriptionTier { .premium }
    var requiredTierForLiveFleetMap: SubscriptionTier { .premium }
    var requiredTierForDriverPerformanceReports: SubscriptionTier { .premiumPlus }
}
