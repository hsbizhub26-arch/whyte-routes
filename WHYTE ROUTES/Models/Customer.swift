import Foundation

struct Customer: Identifiable {
    var id: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    // Defaults false - nobody is notified without explicitly agreeing
    // first. Not yet wired to NotificationService directly (Stop
    // carries its own copy - see Stop.customerOptedIn - since routes
    // don't pull from Customer records yet); this is the standing
    // record of consent for whenever that link gets built.
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
        self.notificationsOptIn = dict["notificationsOptIn"] as? Bool ?? false
    }

    // MARK: - Encode
    func toDict() -> [String: Any] {
        [
            "name": name,
            "address": address,
            "latitude": latitude,
            "longitude": longitude,
            "notificationsOptIn": notificationsOptIn
        ]
    }
}
