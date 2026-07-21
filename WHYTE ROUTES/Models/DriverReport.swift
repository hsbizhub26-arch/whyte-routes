import Foundation
import FirebaseFirestore

struct DriverReport: Identifiable {
    var id: String
    var driverId: String
    var routeId: String
    var stopId: String?
    var notes: String?
    var photoUrl: String?
    var createdAt: Date?
}

// MARK: - Decode (Firestore → Model)
extension DriverReport {
    init?(from dict: [String: Any], id: String) {

        guard let driverId = dict["driverId"] as? String,
              let routeId = dict["routeId"] as? String else {
            return nil
        }

        self.id = id
        self.driverId = driverId
        self.routeId = routeId
        self.stopId = dict["stopId"] as? String
        self.notes = dict["notes"] as? String
        self.photoUrl = dict["photoUrl"] as? String

        if let ts = dict["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = nil
        }
    }
}

// MARK: - Encode (Model → Firestore)
extension DriverReport {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "driverId": driverId,
            "routeId": routeId
        ]

        if let stopId { dict["stopId"] = stopId }
        if let notes { dict["notes"] = notes }
        if let photoUrl { dict["photoUrl"] = photoUrl }
        if let createdAt { dict["createdAt"] = Timestamp(date: createdAt) }

        return dict
    }
}

// MARK: - UI Helper
extension DriverReport {
    var formattedDate: String {
        guard let createdAt else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: createdAt)
    }
}
