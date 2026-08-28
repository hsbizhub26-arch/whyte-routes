import Foundation
import FirebaseFirestore

struct TrackingLink: Identifiable {

    var id: String
    var companyId: String
    var customerName: String
    var address: String
    var driverId: String
    var stopId: String
    var active: Bool
    var createdAt: Date?
    /// The destination itself, denormalised onto the link so the
    /// customer's page can draw the property pin without reading the
    /// stop document - which it has no permission to read, and which
    /// holds contact details a customer shouldn't see.
    var stopLatitude: Double?
    var stopLongitude: Double?
}

extension TrackingLink {

    init?(from dict: [String: Any], id: String, companyId: String) {
        guard let customerName = dict["customerName"] as? String,
              let address = dict["address"] as? String,
              let driverId = dict["driverId"] as? String,
              let stopId = dict["stopId"] as? String else {
            return nil
        }

        self.id = id
        self.companyId = companyId
        self.customerName = customerName
        self.address = address
        self.driverId = driverId
        self.stopId = stopId
        self.active = dict["active"] as? Bool ?? true

        if let ts = dict["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = nil
        }

        self.stopLatitude = dict["stopLatitude"] as? Double
        self.stopLongitude = dict["stopLongitude"] as? Double
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "customerName": customerName,
            "address": address,
            "driverId": driverId,
            "stopId": stopId,
            "active": active
        ]

        if let createdAt {
            d["createdAt"] = Timestamp(date: createdAt)
        }
        if let stopLatitude { d["stopLatitude"] = stopLatitude }
        if let stopLongitude { d["stopLongitude"] = stopLongitude }

        return d
    }

    /// Encodes both the company and the link itself - the customer's
    /// page is unauthenticated, so the URL is the only thing telling
    /// it which company's subcollection to read from.
    ///
    /// Points at Firebase Hosting (hosting/track.html), the same place
    /// the privacy policy and terms are served from. It previously
    /// pointed at whyteroutes.app, a domain the project doesn't own,
    /// so every link generated would have gone nowhere.
    var url: URL? {
        URL(string: "https://whyte-routes.web.app/track?c=\(companyId)&t=\(id)")
    }
}

typealias AppTrackingLink = TrackingLink
