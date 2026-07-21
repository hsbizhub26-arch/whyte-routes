import Foundation
import FirebaseFirestore

/// A single clock-in/clock-out period for one driver, persisted so
/// hours worked survive an app relaunch and can be reported/exported
/// later. Lives at companies/{companyId}/drivers/{driverId}/shifts/{id}.
struct Shift: Identifiable {
    var id: String
    var driverId: String
    var startedAt: Date
    var endedAt: Date?
    var status: String // "active" | "completed"

    var isActive: Bool { status == "active" }

    var durationSeconds: Int {
        let end = endedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }
}

// MARK: - Decode (Firestore → Shift)
extension Shift {
    init?(from dict: [String: Any], id: String) {
        guard let driverId = dict["driverId"] as? String,
              let startedTs = dict["startedAt"] as? Timestamp else {
            return nil
        }
        self.id = id
        self.driverId = driverId
        self.startedAt = startedTs.dateValue()
        self.endedAt = (dict["endedAt"] as? Timestamp)?.dateValue()
        self.status = dict["status"] as? String ?? "active"
    }
}

// MARK: - Encode (Shift → Firestore)
extension Shift {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "driverId": driverId,
            "startedAt": Timestamp(date: startedAt),
            "status": status
        ]
        if let endedAt { dict["endedAt"] = Timestamp(date: endedAt) }
        return dict
    }
}
