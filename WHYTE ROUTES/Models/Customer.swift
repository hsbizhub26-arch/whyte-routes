import Foundation

struct Customer: Identifiable {
    var id: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var phone: String? = nil
    var email: String? = nil
    // Standing instructions for whoever's servicing this property -
    // gate codes, "no scrape the driveway", dog in the yard, where to
    // park. Shown to the driver on the stop itself (see
    // DriverStopView), not just filed away on the customer record.
    var notes: String? = nil
    // Defaults false - nobody is notified without explicitly agreeing
    // first. This is now the SOURCE OF TRUTH once a stop is linked to
    // this record via Stop.customerId (see NotificationService) - the
    // copy still carried on Stop itself is only a fallback for stops
    // created before this record existed or that were never linked.
    var notificationsOptIn: Bool = false
}

// MARK: - Firestore Decode
extension Customer {
    init?(from dict: [String: Any], id: String) {
        guard let name = dict["name"] as? String,
              let address = dict["address"] as? String,
              let latitude = dict["latitude"] as? Double,
              let longitude = dict["longitude"] as? Double else {
            return nil
        }

        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.phone = dict["phone"] as? String
        self.email = dict["email"] as? String
        self.notes = dict["notes"] as? String
        self.notificationsOptIn = dict["notificationsOptIn"] as? Bool ?? false
    }

    // MARK: - Encode
    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "name": name,
            "address": address,
            "latitude": latitude,
            "longitude": longitude,
            "notificationsOptIn": notificationsOptIn
        ]
        if let phone { d["phone"] = phone }
        if let email { d["email"] = email }
        if let notes { d["notes"] = notes }
        return d
    }
}
