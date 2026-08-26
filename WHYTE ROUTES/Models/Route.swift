import Foundation
import FirebaseFirestore
import CoreLocation

struct Route: Identifiable {

    var id: String
    var name: String
    var fleetId: String?
    var driverId: String?
    var status: String
    var createdAt: Date
    var lastUpdated: Date?
    var stops: [Stop]

    // Explicit route endpoints - a depot, the shop, wherever the
    // crew's day actually starts/ends. Independent of the stops list
    // (unlike a stop, these aren't customers), and optional: nil
    // means "no explicit endpoint set", which is the same as every
    // route before this existed - the first/last stop implicitly
    // serves that role, same as it always did.
    var startAddress: String? = nil
    var startLatitude: Double? = nil
    var startLongitude: Double? = nil
    var endAddress: String? = nil
    var endLatitude: Double? = nil
    var endLongitude: Double? = nil
}

extension Route {
    var startCoordinate: CLLocationCoordinate2D? {
        guard let startLatitude, let startLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: startLatitude, longitude: startLongitude)
    }

    var endCoordinate: CLLocationCoordinate2D? {
        guard let endLatitude, let endLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude)
    }
}

// MARK: - Decode (Firestore → Model)
extension Route {
    init?(from dict: [String: Any], id: String) {

        self.id = id
        self.name = dict["name"] as? String ?? "Untitled Route"
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

        self.startAddress = dict["startAddress"] as? String
        self.startLatitude = dict["startLatitude"] as? Double
        self.startLongitude = dict["startLongitude"] as? Double
        self.endAddress = dict["endAddress"] as? String
        self.endLatitude = dict["endLatitude"] as? Double
        self.endLongitude = dict["endLongitude"] as? Double
    }
}

// MARK: - Encode (Model → Firestore)
extension Route {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "status": status,
            "createdAt": Timestamp(date: createdAt),
            "stops": stops.map { $0.toDict() }
        ]

        if let fleetId { dict["fleetId"] = fleetId }
        if let driverId { dict["driverId"] = driverId }
        if let lastUpdated { dict["lastUpdated"] = Timestamp(date: lastUpdated) }
        if let startAddress { dict["startAddress"] = startAddress }
        if let startLatitude { dict["startLatitude"] = startLatitude }
        if let startLongitude { dict["startLongitude"] = startLongitude }
        if let endAddress { dict["endAddress"] = endAddress }
        if let endLatitude { dict["endLatitude"] = endLatitude }
        if let endLongitude { dict["endLongitude"] = endLongitude }

        return dict
    }
}

typealias AppRoute = Route
