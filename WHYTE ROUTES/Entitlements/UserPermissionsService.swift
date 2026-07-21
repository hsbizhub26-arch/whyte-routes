import Foundation
import FirebaseFirestore

/// A user's permissions as stored in Firestore at users/{uid}.
struct UserPermissionsDocument {
    var role: UserRole
    var subscription: String
    var isAdmin: Bool
}

/// Reads/writes the users/{uid} permissions document that is the
/// source of truth for role + subscription access.
final class UserPermissionsService {
    static let shared = UserPermissionsService()
    private init() {}

    private let db = Firestore.firestore()

    func fetch(uid: String) async -> UserPermissionsDocument? {
        guard let snapshot = try? await db.collection("users").document(uid).getDocument(),
              let data = snapshot.data(),
              let roleRaw = data["role"] as? String,
              let role = UserRole(rawValue: roleRaw)
        else {
            return nil
        }

        return UserPermissionsDocument(
            role: role,
            subscription: data["subscription"] as? String ?? "free",
            isAdmin: data["isAdmin"] as? Bool ?? false
        )
    }

    /// Creates the permissions document only if one doesn't already exist -
    /// used to migrate whitelist-based accounts into real Firestore records
    /// the first time they sign in.
    func createIfNeeded(uid: String, email: String, role: UserRole, subscription: String, isAdmin: Bool) async {
        let docRef = db.collection("users").document(uid)

        if let existing = try? await docRef.getDocument(), existing.exists {
            return
        }

        let data: [String: Any] = [
            "uid": uid,
            "email": email,
            "role": role.rawValue,
            "subscription": subscription,
            "isAdmin": isAdmin
        ]

        try? await docRef.setData(data)
    }
}
