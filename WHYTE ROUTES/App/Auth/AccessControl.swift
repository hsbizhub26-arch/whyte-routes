import Foundation

struct AccessControl {

    /// Emails with permanent Owner role + Premium Plus
    static let ownerEmails: Set<String> = [
        "teamdwlandscaping@gmail.com",
        "hopeseneoudom@icloud.com"
    ]

    /// Premium Plus unlock is same as owner list
    static let premiumPlusWhitelist = ownerEmails

    // MARK: - Role Logic
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
