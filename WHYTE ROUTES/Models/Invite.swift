import Foundation
import FirebaseFirestore

/// A pending invitation for someone to join a company. Lives at the
/// top level (invites/{contactValue}) rather than nested under a
/// company, because the whole point is that a not-yet-signed-in
/// person needs to look themselves up by phone/email alone, before
/// they know any companyId. The document ID IS the normalized
/// contact value (lowercased email, or E.164 phone number) - that
/// makes lookup a single, cheap, secure get-by-ID instead of a query,
/// and keeps the security rule simple: nobody can list other
/// people's invites, they can only ever fetch the one matching their
/// own verified sign-in identity.
struct Invite: Identifiable {

    /// Normalized contact value (lowercased email or E.164 phone).
    var id: String

    var companyId: String
    var companyName: String
    var contactMethod: String  // "phone" | "email"
    var role: String           // "driver" | "manager"
    var status: String         // "pending" | "accepted" | "cancelled"
    var invitedByUID: String
    var createdAt: Date
    var expiresAt: Date

    var isExpired: Bool {
        Date() > expiresAt
    }

    var isUsable: Bool {
        status == "pending" && !isExpired
    }
}

extension Invite {

    init?(from dict: [String: Any], id: String) {
        guard let companyId = dict["companyId"] as? String,
              let companyName = dict["companyName"] as? String,
              let contactMethod = dict["contactMethod"] as? String,
              let role = dict["role"] as? String,
              let status = dict["status"] as? String,
              let invitedByUID = dict["invitedByUID"] as? String,
              let createdTS = dict["createdAt"] as? Timestamp,
              let expiresTS = dict["expiresAt"] as? Timestamp
        else {
            return nil
        }

        self.id = id
        self.companyId = companyId
        self.companyName = companyName
        self.contactMethod = contactMethod
        self.role = role
        self.status = status
        self.invitedByUID = invitedByUID
        self.createdAt = createdTS.dateValue()
        self.expiresAt = expiresTS.dateValue()
    }

    func toDict() -> [String: Any] {
        [
            "companyId": companyId,
            "companyName": companyName,
            "contactMethod": contactMethod,
            "role": role,
            "status": status,
            "invitedByUID": invitedByUID,
            "createdAt": Timestamp(date: createdAt),
            "expiresAt": Timestamp(date: expiresAt)
        ]
    }

    /// Normalizes a raw phone/email into the form used as both the
    /// document ID and the value compared against a signed-in user's
    /// auth token claims - must match exactly on both ends.
    static func normalize(_ contactValue: String, method: String) -> String {
        if method == "email" {
            return contactValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        // Phone: keep only a leading + and digits (E.164-ish).
        let stripped = contactValue.filter { $0.isNumber || $0 == "+" }
        return stripped
    }
}
