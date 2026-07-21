import Foundation
import FirebaseFirestore

struct Route: Identifiable {

    var id: String
    var fleetId: String?
    var driverId: String?
    var status: String
    var createdAt: Date
    var lastUpdated: Date?
    var stops: [Stop]
}

// MARK: - Decode (Firestore → Model)
extension Route {
    init?(from dict: [String: Any], id: String) {

        self.id = id
        self.fleetId = dict["fleetId"] as? String
        self.driverId = dict["driverId"] as? String
        self.status = dict["status"] as? String ?? "pending"

        // createdAt
        if let ts = dict["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = Date()
        }

        // lastUpdated
        if let ts = dict["lastUpdated"] as? Timestamp {
            self.lastUpdated = ts.dateValue()
        } else {
            self.lastUpdated = nil
        }

        // decode stops
        let stopDicts = dict["stops"] as? [[String: Any]] ?? []
        self.stops = stopDicts.compactMap { Stop(from: $0) }
    }
}

// MARK: - Encode (Model → Firestore)
extension Route {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "status": status,
            "createdAt": Timestamp(date: createdAt),
            "stops": stops.map { $0.toDict() }
        ]

        if let fleetId { dict["fleetId"] = fleetId }
        if let driverId { dict["driverId"] = driverId }
        if let lastUpdated { dict["lastUpdated"] = Timestamp(date: lastUpdated) }

        return dict
    }
}

typealias AppRoute = Route
