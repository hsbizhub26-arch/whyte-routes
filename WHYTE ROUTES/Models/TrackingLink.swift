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

        return d
    }

    /// Encodes both the company and the link itself - a customer's
    /// tracking view is unauthenticated, so the URL is the only thing
    /// that tells it which company's subcollection to read from.
    var url: URL? {
        URL(string: "https://whyteroutes.app/tracking/\(companyId)/\(id)")
    }
}

typealias AppTrackingLink = TrackingLink
