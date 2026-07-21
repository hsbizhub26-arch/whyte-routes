import Foundation

struct LocalEntitlementStore {

    static func save(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func save(_ value: Double, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func load(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func loadDouble(_ key: String) -> Double {
        UserDefaults.standard.double(forKey: key)
    }
}
