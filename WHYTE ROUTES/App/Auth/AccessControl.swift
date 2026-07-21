import Foundation

struct AccessControl {

    /// Firebase UIDs of WHYTE ROUTES platform owners - manage all
    /// companies, subscriptions, and platform-wide settings. This is
    /// deliberately a small, fixed, code-level list (unlike company
    /// roles, which live entirely in Firestore) since there are only
    /// ever a handful of these accounts. UIDs are the source of truth -
    /// they don't change if an account's email does.
    static let platformAdminUIDs: Set<String> = [
        "x5cxMZN5TKTXcIwrVMAPmQJOp3R2", // teamdwlandscaping@gmail.com
        "bMeTRuhikKVlCU6rE8QFBp0TXAz1"  // hopeseneoudom@icloud.com
    ]

    /// Email fallback, used only until a user's Firestore users/{uid}
    /// permissions document has been created (see UserPermissionsService).
    static let platformAdminEmails: Set<String> = [
        "teamdwlandscaping@gmail.com",
        "hopeseneoudom@icloud.com"
    ]

    static func isPlatformAdmin(uid: String?, email: String?) -> Bool {
        if let uid, platformAdminUIDs.contains(uid) { return true }
        if let email = email?.lowercased(), platformAdminEmails.contains(email) { return true }
        return false
    }
}
