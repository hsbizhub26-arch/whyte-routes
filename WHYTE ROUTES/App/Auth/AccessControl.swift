import Foundation

struct AccessControl {

    /// Firebase UIDs with permanent Owner role + Premium Plus. This is the
    /// real source of truth - UIDs don't change if an account's email does.
    static let ownerUIDs: Set<String> = [
        "x5cxMZN5TKTXcIwrVMAPmQJOp3R2", // teamdwlandscaping@gmail.com
        "bMeTRuhikKVlCU6rE8QFBp0TXAz1"  // hopeseneoudom@icloud.com
    ]

    /// Email fallback, used only until a user's Firestore users/{uid}
    /// permissions document has been created (see UserPermissionsService).
    static let ownerEmails: Set<String> = [
        "teamdwlandscaping@gmail.com",
        "hopeseneoudom@icloud.com"
    ]

    /// Premium Plus unlock is same as owner list
    static let premiumPlusWhitelist = ownerEmails

    // MARK: - Role Logic
    static func isOwner(uid: String?, email: String?) -> Bool {
        if let uid, ownerUIDs.contains(uid) { return true }
        if let email = email?.lowercased(), ownerEmails.contains(email) { return true }
        return false
    }

    static func role(for email: String?) -> UserRole {
        guard let email = email?.lowercased() else { return .none }

        if ownerEmails.contains(email) {
            return .owner
        } else {
            return .driver
        }
    }

    // MARK: - Entitlement Logic
    static func isWhitelisted(_ email: String?) -> Bool {
        guard let email = email?.lowercased() else { return false }
        return premiumPlusWhitelist.contains(email)
    }
}
