import Foundation
import CoreLocation
import SwiftUI
import FirebaseFirestore

struct Driver: Identifiable {

    // MARK: - Core Fields
    var id: String
    var name: String
    var phone: String?
    var vehicle: String
    var fleetId: String?

    // MARK: - Route / Tracking Info
    var activeRoute: String?
    var latitude: Double?
    var longitude: Double?
    var lastUpdated: Date?
    var colorHex: String?

    // MARK: - Map Coordinate Helper
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lng = longitude else { return nil }
        return .init(latitude: lat, longitude: lng)
    }

    // MARK: - UI Color Helper
    var color: Color {
        Color(hex: colorHex?.isEmpty == false ? colorHex! : "F5C451")
    }
}

// MARK: - Decode (Firestore → Driver)
extension Driver {

    init?(from dict: [String: Any], id: String) {

        // Safe name fallback (never crash)
        self.id = id
        self.name = dict["name"] as? String ?? "Unnamed Driver"

        // Basic fields
        self.phone = dict["phone"] as? String
        self.vehicle = dict["vehicle"] as? String ?? ""
        self.fleetId = dict["fleetId"] as? String
        self.activeRoute = dict["activeRoute"] as? String
        self.colorHex = dict["colorHex"] as? String

        // Latitude (new or legacy)
        if let lat = dict["latitude"] as? Double {
            self.latitude = lat
        } else if let latLegacy = dict["lat"] as? Double {
            self.latitude = latLegacy
        } else {
            self.latitude = nil
        }

        // Longitude (new or legacy)
        if let lng = dict["longitude"] as? Double {
            self.longitude = lng
        } else if let lngLegacy = dict["lng"] as? Double {
            self.longitude = lngLegacy
        } else {
            self.longitude = nil
        }

        // Timestamp safe decode
        if let ts = dict["lastUpdated"] as? Timestamp {
            self.lastUpdated = ts.dateValue()
        } else {
            self.lastUpdated = nil
        }
    }
}

// MARK: - Encode (Driver → Firestore)
extension Driver {

    func toDict() -> [String: Any] {

        var dict: [String: Any] = [
            "name": name,
            "vehicle": vehicle
        ]

        if let phone { dict["phone"] = phone }
        if let fleetId { dict["fleetId"] = fleetId }
        if let activeRoute { dict["activeRoute"] = activeRoute }
        if let latitude { dict["latitude"] = latitude }
        if let longitude { dict["longitude"] = longitude }
        if let colorHex { dict["colorHex"] = colorHex }
        if let lastUpdated { dict["lastUpdated"] = Timestamp(date: lastUpdated) }

        return dict
    }
}

typealias AppDriver = Driver
