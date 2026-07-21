import Foundation

struct AccessControl {

    /// Emails with permanent Manager role + Premium Plus
    static let managerEmails: Set<String> = [
        "w0lfiebabe@icloud.com",          // YOU
        "hopeseneoudom@hotmail.com",      // YOU
        "devonwhyte9954@gmail.com",       // DW
        "dwlandscaping@hotmail.com",
        "teamdwlandscaping@gmail.com"
    ]

    /// Premium Plus unlock is same as manager list
    static let premiumPlusWhitelist = managerEmails

    // MARK: - Role Logic
    static func role(for email: String?) -> UserRole {
        guard let email = email?.lowercased() else { return .none }

        if managerEmails.contains(email) {
            return .manager
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
