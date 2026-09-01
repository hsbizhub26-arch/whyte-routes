import Foundation
import FirebaseFirestore

struct TrackingLink: Identifiable {

    var id: String
    var companyId: String
    var customerName: String
    var address: String
    /// Optional and NO LONGER PUBLISHED. The tracking-link document is
    /// world-readable to whoever holds the link, and an adversarial
    /// review flagged this as a stable per-employee identifier being
    /// exposed unauthenticated for no functional reason - nothing in
    /// the customer page reads it, and stop/link association is done
    /// by stopId. Kept decodable so links written before this change
    /// still parse.
    var driverId: String?
    var stopId: String
    /// WHICH CUSTOMER this link belongs to, as opposed to which stop.
    ///
    /// Links used to be identified by stopId alone, which quietly
    /// assumed a stop always means the same person. It doesn't: the
    /// owner's "Change Customer" picker re-points an existing stop at
    /// somebody else and keeps the same stop.id. A link minted for
    /// customer A therefore stayed "the active link for this stop"
    /// after the stop became customer B's, and the driver's app kept
    /// publishing live position into it - A's page still showing A's
    /// own name and address while the coordinates drove to, and then
    /// parked at, B's house.
    ///
    /// nil for a one-off stop typed in by hand with no standing
    /// Customer record, and for links written before this field
    /// existed - see `belongsTo(_:)` for how both are handled.
    ///
    /// Safe on a world-readable document in a way driverId was not:
    /// this identifies the person holding the link, not a third
    /// party, and the customers collection stays unreadable without a
    /// login either way.
    var customerId: String?
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
              let stopId = dict["stopId"] as? String else {
            return nil
        }
        let driverId = dict["driverId"] as? String

        self.id = id
        self.companyId = companyId
        self.customerName = customerName
        self.address = address
        self.driverId = driverId
        self.stopId = stopId
        self.customerId = dict["customerId"] as? String
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
            "stopId": stopId,
            "active": active
        ]

        if let customerId { d["customerId"] = customerId }
        if let createdAt {
            d["createdAt"] = Timestamp(date: createdAt)
        }
        if let stopLatitude { d["stopLatitude"] = stopLatitude }
        if let stopLongitude { d["stopLongitude"] = stopLongitude }

        return d
    }

    /// Whether this link still belongs to the person the stop points
    /// at right now. Anything that publishes a live position must ask
    /// this first: matching stopId is NOT proof the recipient is the
    /// same customer the link was minted for.
    ///
    /// Deliberately fails closed in the ambiguous cases:
    ///
    ///  - A link written before customerId existed has none recorded,
    ///    so a stop that has one can never match it. The link is
    ///    treated as somebody else's and superseded. Cheap: staff
    ///    re-send and the customer gets a fresh URL.
    ///  - A one-off stop with no Customer record has nothing stable to
    ///    compare, so it falls back to the name and address that were
    ///    denormalised onto the link. Those are byte-identical for an
    ///    untouched stop, and any edit to either supersedes - which is
    ///    also the right call, since a changed address means the pin
    ///    on the customer's map has moved.
    ///
    /// The name fallback mirrors the Cloud Function's `|| "Customer"`
    /// exactly; without that an unnamed one-off stop would compare
    /// "Customer" against "" and supersede its own link on every send.
    func belongsTo(_ stop: Stop) -> Bool {
        if customerId != nil || stop.customerId != nil {
            return customerId == stop.customerId
        }
        let expectedName = (stop.customerName?.isEmpty == false) ? stop.customerName! : "Customer"
        return address == stop.address && customerName == expectedName
    }

    // THE CLIENT NO LONGER BUILDS TRACKING URLS. There used to be a
    // `url` property here and it is deliberately gone, not moved.
    //
    // Three reasons, any one of which is sufficient. The shape was the
    // superseded ?c=<companyId>&t=<linkId> form rather than the short
    // /t/<token> one. It interpolated companyId without percent-encoding,
    // which is precisely the bug that shipped broken links to a tenant
    // whose document id contains a space - the SMS client truncated the
    // URL at that space and the customer got a page that could never
    // load. And the token it would need does not exist on the client at
    // all: ensureTrackingLink mints it server-side, inside the Cloud
    // Function, and returns the finished URL.
    //
    // Anything needing a tracking URL calls sendTrackingLink and uses
    // what comes back. A second builder here could only ever drift from
    // the real one, and the last time it drifted it drifted into a
    // domain nobody owns.
}

typealias AppTrackingLink = TrackingLink
