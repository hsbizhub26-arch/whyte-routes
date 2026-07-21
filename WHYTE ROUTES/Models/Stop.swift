import Foundation
import CoreLocation

struct Stop: Identifiable {

    var id: String
    var customerPhone: String?
    var address: String
    var latitude: Double?
    var longitude: Double?
    var sequence: Int
    var isCompleted: Bool

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude,
              let lng = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

extension Stop {

    // MARK: Firestore initializer (safe)
    init?(from dict: [String: Any]) {

        // Create an id if none is provided
        let rawId = (dict["id"] as? String) ?? UUID().uuidString

        guard let address = dict["address"] as? String else {
            return nil
        }

        self.id = rawId
        self.customerPhone = dict["customerPhone"] as? String
        self.address = address
        self.latitude = dict["latitude"] as? Double
        self.longitude = dict["longitude"] as? Double
        self.sequence = dict["sequence"] as? Int ?? 0
        self.isCompleted = dict["isCompleted"] as? Bool ?? false
    }

    // MARK: Swift initializer (manual creation)
    init(
        id: String = UUID().uuidString,
        customerPhone: String? = nil,
        address: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        sequence: Int = 0,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.customerPhone = customerPhone
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.sequence = sequence
        self.isCompleted = isCompleted
    }

    // MARK: Encode for Firestore
    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "address": address,
            "sequence": sequence,
            "isCompleted": isCompleted
        ]
        if let customerPhone { d["customerPhone"] = customerPhone }
        if let latitude { d["latitude"] = latitude }
        if let longitude { d["longitude"] = longitude }
        return d
    }
}

// Alias
typealias AppStop = Stop
