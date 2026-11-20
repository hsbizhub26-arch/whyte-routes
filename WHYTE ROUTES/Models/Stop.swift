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
    // Cached from Customer.notes the same way the fields above are -
    // gate codes, "no scrape", dog in the yard. Shown prominently on
    // DriverStopView so a driver sees it without hunting for it.
    var driverNotes: String? = nil
    var address: String
    var latitude: Double? = nil
    var longitude: Double? = nil
    var order: Int = 0
    var isCompleted: Bool = false
    var isSkipped: Bool = false

    /// Still ahead of the driver: neither done nor skipped.
    var isPending: Bool { !isCompleted && !isSkipped }

    var driverId: String? = nil
    var status: String = JobStatus.scheduled.rawValue

    // Set the moment each status transition happens (DriverStopViewModel) -
    // what the time-accounting report is built from: travel time is
    // arrivedAt - enRouteAt, service time is completedAt - arrivedAt.
    var enRouteAt: Date? = nil
    var arrivedAt: Date? = nil
    var completedAt: Date? = nil

    /// The service-history record this stop's current run is writing
    /// into (companies/{c}/serviceHistory/{id}). The stop itself is
    /// reused storm after storm and its three timestamps above get
    /// overwritten each time; the history record is the permanent
    /// copy. See ServiceHistoryRepository for when a new one starts.
    var openVisitId: String? = nil
    /// B8: optional time window, minutes after midnight in the company's
    /// time zone (e.g. 480 = 8:00 AM). Both nil = no window. Written only
    /// when set (merge writes), so a driver's write can never add or
    /// strip it; clearing is an explicit owner-side delete.
    var windowStartMinute: Int? = nil
    var windowEndMinute: Int? = nil

    var hasTimeWindow: Bool { windowStartMinute != nil && windowEndMinute != nil }

    /// "8:00 AM – 10:00 AM"
    var timeWindowText: String? {
        guard let a = windowStartMinute, let b = windowEndMinute else { return nil }
        func fmt(_ m: Int) -> String {
            let h = (m / 60) % 24, mm = m % 60
            let h12 = h % 12 == 0 ? 12 : h % 12
            return String(format: "%d:%02d %@", h12, mm, h < 12 ? "AM" : "PM")
        }
        return "\(fmt(a)) – \(fmt(b))"
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude,
              let lng = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Time on the property: arrivedAt -> completedAt, or nil when that
    /// pair can't be trusted as one visit.
    ///
    /// Guards on STATUS as well as the two timestamps, for the same
    /// reason DriverStopViewModel.atPropertyStart does: a stop reset
    /// before the reset path deleted its timestamps can still carry an
    /// old arrivedAt/completedAt while it is merely scheduled. Only a
    /// stop that is actually completed right now gets a number. A
    /// completion stamped before the arrival is a leftover from such a
    /// reset, never a real visit, so that is refused too.
    ///
    /// No age ceiling, deliberately: a crew can hold a commercial lot
    /// for a whole storm, and a huge number is the visible sign that a
    /// visit was never closed out properly.
    var dwellTime: TimeInterval? {
        guard isCompleted,
              status == JobStatus.completed.rawValue,
              let arrived = arrivedAt,
              let completed = completedAt,
              completed >= arrived else { return nil }
        return completed.timeIntervalSince(arrived)
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
        self.driverNotes = dict["driverNotes"] as? String
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
        self.openVisitId = dict["openVisitId"] as? String
        self.windowStartMinute = (dict["windowStartMinute"] as? NSNumber)?.intValue
        self.windowEndMinute = (dict["windowEndMinute"] as? NSNumber)?.intValue
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
        if let driverNotes { d["driverNotes"] = driverNotes }
        if let latitude { d["latitude"] = latitude }
        if let longitude { d["longitude"] = longitude }
        if let driverId { d["driverId"] = driverId }
        if let enRouteAt { d["enRouteAt"] = Timestamp(date: enRouteAt) }
        if let arrivedAt { d["arrivedAt"] = Timestamp(date: arrivedAt) }
        if let completedAt { d["completedAt"] = Timestamp(date: completedAt) }
        if let openVisitId { d["openVisitId"] = openVisitId }
        if let windowStartMinute, let windowEndMinute {
            d["windowStartMinute"] = windowStartMinute
            d["windowEndMinute"] = windowEndMinute
        }
        return d
    }
}

// Alias
typealias AppStop = Stop
