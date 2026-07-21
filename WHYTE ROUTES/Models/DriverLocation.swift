import Foundation
import CoreLocation
import FirebaseFirestore

struct DriverLocation: Identifiable, Codable {
    var id: String = UUID().uuidString
    var latitude: Double
    var longitude: Double
    var timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Firestore initializer
extension DriverLocation {

    init?(from dict: [String: Any], id: String? = nil) {

        // Support both new and legacy Firestore field names
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

        var time: Date = Date()
        if let ts = dict["timestamp"] as? Timestamp {
            time = ts.dateValue()
        }

        self.init(
            id: id ?? UUID().uuidString,
            latitude: latitude,
            longitude: longitude,
            timestamp: time
        )
    }
}

// MARK: - Distance helper
extension DriverLocation {
    func distance(to: DriverLocation) -> CLLocationDistance {
        let loc1 = CLLocation(latitude: latitude, longitude: longitude)
        let loc2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return loc1.distance(from: loc2)
    }
}
