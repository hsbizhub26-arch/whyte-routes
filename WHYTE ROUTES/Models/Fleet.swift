import Foundation
import FirebaseFirestore

struct Fleet: Identifiable {
    var id: String
    var ownerId: String
    var name: String
    var createdAt: Date?
}

// MARK: - Decode from Firestore
extension Fleet {
    init?(from dict: [String: Any], id: String) {
        guard let ownerId = dict["ownerId"] as? String,
              let name = dict["name"] as? String else {
            return nil
        }

        self.id = id
        self.ownerId = ownerId
        self.name = name

        // createdAt may be missing or still a serverTimestamp placeholder
        if let ts = dict["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = nil
        }
    }
}

// MARK: - Encode to Firestore
extension Fleet {
    func toDict() -> [String: Any] {
        var data: [String: Any] = [
            "ownerId": ownerId,
            "name": name
        ]

        if let createdAt {
            data["createdAt"] = Timestamp(date: createdAt)
        } else {
            data["createdAt"] = FieldValue.serverTimestamp()
        }

        return data
    }
}

// MARK: - Convenience Init
extension Fleet {
    init(id: String,
         ownerId: String,
         name: String,
         createdAt: Date? = Date()) {
        self.id = id
        self.ownerId = ownerId
        self.name = name
        self.createdAt = createdAt
    }
}
