import Foundation
import Combine

// MARK: - Production persistence keys
struct EntitlementStorageKeys {
    static let premiumPlus = "entitlement.premiumPlus"
    static let premium = "entitlement.premium"
    static let premiumPlusSource = "entitlement.premiumPlus.source"
    static let premiumSource = "entitlement.premium.source"
}

// MARK: - Concrete persistence utility
enum EntitlementStore {
    static func save(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func save(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func loadBool(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func loadString(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }
}

@MainActor
final class AppEntitlements: ObservableObject {

    static let shared = AppEntitlements()
    private init() {
        restoreFromDefaults()
    }

    @Published var premiumUnlocked: Bool = false
    @Published var premiumPlusUnlocked: Bool = false

    // Optional: retain last-known source (useful for audits/support)
    @Published var premiumSource: String?
    @Published var premiumPlusSource: String?

    // MARK: - Premium+
    func setPremiumPlus(unlocked: Bool, source: String) {
        premiumPlusUnlocked = unlocked
        premiumPlusSource = source
        EntitlementStore.save(unlocked, forKey: EntitlementStorageKeys.premiumPlus)
        EntitlementStore.save(source, forKey: EntitlementStorageKeys.premiumPlusSource)
    }

    // MARK: - Premium
    func setPremium(unlocked: Bool, source: String) {
        premiumUnlocked = unlocked
        premiumSource = source
        EntitlementStore.save(unlocked, forKey: EntitlementStorageKeys.premium)
        EntitlementStore.save(source, forKey: EntitlementStorageKeys.premiumSource)
    }

    // MARK: - Restore
    func restoreFromDefaults() {
        premiumPlusUnlocked = EntitlementStore.loadBool(EntitlementStorageKeys.premiumPlus)
        premiumUnlocked = EntitlementStore.loadBool(EntitlementStorageKeys.premium)

        // Restore sources if present
        premiumPlusSource = EntitlementStore.loadString(EntitlementStorageKeys.premiumPlusSource)
        premiumSource = EntitlementStore.loadString(EntitlementStorageKeys.premiumSource)
    }
}
