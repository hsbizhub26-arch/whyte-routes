import Foundation
import CoreLocation
import FirebaseFirestore

struct LiveLocation: Identifiable, Codable {
    var id: String           // usually driverId
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Firestore Decode
extension LiveLocation {
    init?(from dict: [String: Any], id: String) {

        // Support both new + legacy fields written by LocationService
        let lat =
            (dict["latitude"] as? Double) ??
            (dict["lat"] as? Double)

        let lng =
            (dict["longitude"] as? Double) ??
            (dict["lng"] as? Double)

        guard let latitude = lat,
              let longitude = lng else {
            return nil
        }

        var time = Date()
        if let ts = dict["timestamp"] as? Timestamp {
            time = ts.dateValue()
        }

        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = time
    }
}

// MARK: - Encode
extension LiveLocation {
    func toDict() -> [String: Any] {
        [
            "latitude": latitude,
            "longitude": longitude,
            "timestamp": Timestamp(date: timestamp)
        ]
    }
}
