import Foundation
import CoreLocation

struct Stop: Identifiable {

    var id: String = UUID().uuidString
    var customerName: String? = nil
    var customerPhone: String? = nil
    var address: String
    var latitude: Double? = nil
    var longitude: Double? = nil
    var order: Int = 0
    var isCompleted: Bool = false
    var isSkipped: Bool = false
    var driverId: String? = nil

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude,
              let lng = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

extension Stop {

    // MARK: Firestore initializer (safe)
    init?(from dict: [String: Any], id: String? = nil) {

        // Create an id if none is provided
        let rawId = id ?? (dict["id"] as? String) ?? UUID().uuidString

        guard let address = dict["address"] as? String else {
            return nil
        }

        self.id = rawId
        self.customerName = dict["customerName"] as? String
        self.customerPhone = dict["customerPhone"] as? String
        self.address = address
        self.latitude = dict["latitude"] as? Double
        self.longitude = dict["longitude"] as? Double
        self.order = (dict["order"] as? Int) ?? (dict["sequence"] as? Int) ?? 0
        self.isCompleted = dict["isCompleted"] as? Bool ?? false
        self.isSkipped = dict["isSkipped"] as? Bool ?? false
        self.driverId = dict["driverId"] as? String
    }

    // MARK: Encode for Firestore
    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "address": address,
            "order": order,
            "isCompleted": isCompleted,
            "isSkipped": isSkipped
        ]
        if let customerName { d["customerName"] = customerName }
        if let customerPhone { d["customerPhone"] = customerPhone }
        if let latitude { d["latitude"] = latitude }
        if let longitude { d["longitude"] = longitude }
        if let driverId { d["driverId"] = driverId }
        return d
    }
}

// Alias
typealias AppStop = Stop
