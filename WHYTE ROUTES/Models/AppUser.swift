import Foundation
import FirebaseFirestore

struct AppUser: Identifiable {
    var id: String
    var email: String
    var name: String
    var role: UserRole
    var fleetId: String?
    var createdAt: Date?
}

// MARK: - Roles
enum UserRole: String, Codable {
    case owner
    case manager
    case driver
}

// MARK: - Firestore Decode
extension AppUser {
    init?(from dict: [String: Any], id: String) {
        // Required fields
        guard let email = dict["email"] as? String,
              let name = dict["name"] as? String
        else { return nil }

        // Role
        let roleRaw = dict["role"] as? String ?? "driver"
        let role = UserRole(rawValue: roleRaw) ?? .driver

        // Assign
        self.id = id
        self.email = email
        self.name = name
        self.role = role
        self.fleetId = dict["fleetId"] as? String

        // Created At
        if let ts = dict["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = nil
        }
    }

    // MARK: - Firestore Encode
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "email": email,
            "name": name,
            "role": role.rawValue
        ]

        if let fleetId { dict["fleetId"] = fleetId }
        if let createdAt { dict["createdAt"] = Timestamp(date: createdAt) }

        return dict
    }
}
