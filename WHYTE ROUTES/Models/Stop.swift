import Foundation
import CoreLocation
import FirebaseFirestore

// Job status for this stop, distinct from isCompleted/isSkipped -
// those two are left exactly as-is (existing screens already depend
// on them) and stay in sync with status rather than being replaced.
// "scheduled" has no separate "confirm the appointment" trigger yet -
// nothing in the app tracks a service date/time to confirm, so that
// notification type isn't wired up (would need a scheduling feature
// first, not just a status field).
enum JobStatus: String {
    case scheduled
    case enRoute
    case arrived
    case completed
}

struct Stop: Identifiable {

    var id: String = UUID().uuidString
    // nil for stops created before this field existed, or ones never
    // linked to a standing Customer record. When set, this is the
    // real source of truth for contact info/consent - see
    // NotificationService, which looks up the Customer record first
    // and only falls back to this stop's own cached fields below when
    // customerId is nil.
    var customerId: String? = nil
    // Cached copy, filled in automatically when a customer is picked
    // (see CustomerPickerView) - keeps the stop self-contained for
    // display without a join on every read. Still the primary source
    // for legacy stops that predate customer linking.
    var customerName: String? = nil
    var customerPhone: String? = nil
    var customerEmail: String? = nil
    var customerOptedIn: Bool = false
    var address: String
    var latitude: Double? = nil
    var longitude: Double? = nil
    var order: Int = 0
    var isCompleted: Bool = false
    var isSkipped: Bool = false
    var driverId: String? = nil
    var status: String = JobStatus.scheduled.rawValue

    // Set the moment each status transition happens (DriverStopViewModel) -
    // what the time-accounting report is built from: travel time is
    // arrivedAt - enRouteAt, service time is completedAt - arrivedAt.
    var enRouteAt: Date? = nil
    var arrivedAt: Date? = nil
    var completedAt: Date? = nil

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
        self.customerId = dict["customerId"] as? String
        self.customerName = dict["customerName"] as? String
        self.customerPhone = dict["customerPhone"] as? String
        self.customerEmail = dict["customerEmail"] as? String
        self.customerOptedIn = dict["customerOptedIn"] as? Bool ?? false
        self.address = address
        self.latitude = dict["latitude"] as? Double
        self.longitude = dict["longitude"] as? Double
        self.order = (dict["order"] as? Int) ?? (dict["sequence"] as? Int) ?? 0
        self.isCompleted = dict["isCompleted"] as? Bool ?? false
        self.isSkipped = dict["isSkipped"] as? Bool ?? false
        self.driverId = dict["driverId"] as? String
        self.status = dict["status"] as? String ?? JobStatus.scheduled.rawValue
        self.enRouteAt = (dict["enRouteAt"] as? Timestamp)?.dateValue()
        self.arrivedAt = (dict["arrivedAt"] as? Timestamp)?.dateValue()
        self.completedAt = (dict["completedAt"] as? Timestamp)?.dateValue()
    }

    // MARK: Encode for Firestore
    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "address": address,
            "order": order,
            "isCompleted": isCompleted,
            "isSkipped": isSkipped,
            "status": status,
            "customerOptedIn": customerOptedIn
        ]
        if let customerId { d["customerId"] = customerId }
        if let customerName { d["customerName"] = customerName }
        if let customerPhone { d["customerPhone"] = customerPhone }
        if let customerEmail { d["customerEmail"] = customerEmail }
        if let latitude { d["latitude"] = latitude }
        if let longitude { d["longitude"] = longitude }
        if let driverId { d["driverId"] = driverId }
        if let enRouteAt { d["enRouteAt"] = Timestamp(date: enRouteAt) }
        if let arrivedAt { d["arrivedAt"] = Timestamp(date: arrivedAt) }
        if let completedAt { d["completedAt"] = Timestamp(date: completedAt) }
        return d
    }
}

// Alias
typealias AppStop = Stop
