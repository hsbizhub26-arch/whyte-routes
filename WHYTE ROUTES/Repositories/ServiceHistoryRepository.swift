import Foundation
import FirebaseAuth
import FirebaseFirestore

// MARK: - Permanent service history
//
// companies/{companyId}/serviceHistory/{visitId}
//
// ONE record per property per storm. This exists because the stop
// document can't be the record of work done: a property has a single
// stop per route, reused every storm, holding a single enRouteAt /
// arrivedAt / completedAt. The owner resets it between storms and the
// next run writes straight over the last one. One real property ran
// Nov 3, Nov 5 and Nov 16 and only Nov 3's completed time survived -
// and only by accident. That is the billing hole this closes.
//
// The record is append-only:
//  - each timestamp (and the GPS spot at done) is filled in ONCE and
//    can never be changed afterwards, by anyone, from any app;
//  - nothing can delete it;
//  - routes, stops and the route editor never write to it except to
//    add the next event of the visit that's in progress.
// firestore.rules enforces all three - see match /serviceHistory.
//
// source tells the owner where a record came from:
//  "app"                 recorded live by the app as the work happened
//  "recovered_from_logs" rebuilt afterwards from the text-message log
//                        (server-side backfill only, never the app)
//  "owner_entered"       typed in later by the owner (not built yet)
@MainActor
final class ServiceHistoryRepository {

    static let shared = ServiceHistoryRepository()
    private init() {}

    private let db = Firestore.firestore()

    enum Event {
        case enRoute, arrived, completed, skipped
    }

    /// A visit left open longer than this belongs to an earlier storm
    /// (the app was closed mid-route, a stop was never finished) and is
    /// not reused - the next event starts a fresh record instead of
    /// stapling tonight's work onto last week's visit.
    static let openVisitMaxAge: TimeInterval = 18 * 60 * 60

    // MARK: Which record does this event belong to?

    /// Returns the history record this event should write into, and
    /// whether that record still has to be created.
    ///
    /// Call it with the stop as it is BEFORE the event is applied: the
    /// decision rests on the stop's current status. A visit is reused
    /// only while it is genuinely in progress (en route or arrived),
    /// recent, and recorded on the stop. Anything else - a stop coming
    /// back from "scheduled" after a reset, a completed stop, a visit
    /// abandoned days ago - starts a new record.
    func visitId(for stop: Stop, event: Event, at date: Date = Date()) -> (id: String, isNew: Bool) {
        if let open = stop.openVisitId, isInProgress(stop, at: date) {
            return (open, false)
        }
        return (Self.newVisitId(stopId: stop.id, at: date), true)
    }

    private func isInProgress(_ stop: Stop, at date: Date) -> Bool {
        let status = JobStatus(rawValue: stop.status)
        guard status == .enRoute || status == .arrived else { return false }
        guard let last = stop.arrivedAt ?? stop.enRouteAt else { return false }
        return date.timeIntervalSince(last) < Self.openVisitMaxAge
    }

    /// "{stopId}_{UTC start time}". Readable in the console, sorts by
    /// time within a property, and can't collide across storms.
    static func newVisitId(stopId: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "\(stopId)_\(f.string(from: date))"
    }

    // MARK: Write

    /// Records one event of a visit. Fire-and-forget on purpose: the
    /// Firestore SDK keeps the write in its on-device cache until it
    /// reaches the server (across a relaunch too), and a slow history
    /// write must never hold up a driver standing in a driveway.
    ///
    /// `recordedVia` is "driver_app" for the stop screen, or
    /// "owner_edit_route" when the owner/manager ticks a stop done from
    /// the route editor - kept so a billing dispute can tell the two
    /// apart. Owner ticks carry no GPS: where the owner's phone is says
    /// nothing about where the truck was.
    func record(_ event: Event,
                stop: Stop,
                routeId: String,
                routeName: String?,
                visitId: String,
                isNew: Bool,
                at date: Date = Date(),
                recordedVia: String = "driver_app") {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ ServiceHistory: no company set - visit \(visitId) not recorded")
            return
        }
        let ref = db.collection("companies").document(companyId)
            .collection("serviceHistory").document(visitId)

        let eventFields = fields(for: event, at: date, recordedVia: recordedVia)

        if isNew {
            var full = identityFields(stop: stop, routeId: routeId, routeName: routeName,
                                      at: date, recordedVia: recordedVia)
            full.merge(eventFields) { _, new in new }
            ref.setData(full, merge: true) { error in
                if let error {
                    print("❌ ServiceHistory: couldn't create \(visitId): \(error.localizedDescription)")
                } else {
                    print("✅ ServiceHistory: created \(visitId) (\(event))")
                }
            }
            return
        }

        // Adding to a visit already in progress: send ONLY the new
        // event's fields. Resending the identity fields would be
        // refused by the rules the moment any of them differed (a
        // customer renamed mid-storm, say), and the event would be lost
        // with them.
        ref.setData(eventFields, merge: true) { [weak self] error in
            guard let error else {
                print("✅ ServiceHistory: added \(event) to \(visitId)")
                return
            }
            // The record the stop points at doesn't exist - its create
            // never landed (signed out mid-write, an older build, the
            // rules refusing an orphan update). Create it now, with
            // this event, rather than drop the event.
            print("⚠️ ServiceHistory: update of \(visitId) refused (\(error.localizedDescription)) - creating it instead")
            Task { @MainActor in
                guard let self else { return }
                var full = self.identityFields(stop: stop, routeId: routeId, routeName: routeName,
                                               at: date, recordedVia: recordedVia)
                full.merge(eventFields) { _, new in new }
                ref.setData(full, merge: true) { error in
                    if let error {
                        print("❌ ServiceHistory: couldn't record \(visitId): \(error.localizedDescription)")
                    } else {
                        print("✅ ServiceHistory: created \(visitId) on fallback (\(event))")
                    }
                }
            }
        }
    }

    // MARK: Reason chips

    /// The driver's optional "why did this take longer" answer. Written
    /// before the visit is completed (or with it); the rules refuse any
    /// change once the server has taken its completion snapshot. A write
    /// that fails never matters to the driver - it is optional.
    func recordReason(visitId: String?, code: String, text: String?) {
        guard let visitId, let companyId = CompanySession.shared.currentCompanyId else { return }
        var d: [String: Any] = ["reasonCode": code]
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if code == "other", !trimmed.isEmpty {
            d["reasonText"] = String(trimmed.prefix(RouteMemory.REASON_OTHER_MAX_CHARS))
        } else {
            d["reasonText"] = FieldValue.delete()    // free text is only allowed with "Other"
        }
        db.collection("companies").document(companyId).collection("serviceHistory").document(visitId)
            .setData(d, merge: true) { error in
                if let error { print("⚠️ ServiceHistory: reason not saved for \(visitId): \(error.localizedDescription)") }
            }
    }

    // MARK: Field building

    private func identityFields(stop: Stop, routeId: String, routeName: String?,
                                at date: Date, recordedVia: String) -> [String: Any] {
        var d: [String: Any] = [
            "stopId": stop.id,
            "routeId": routeId,
            "address": stop.address,
            "serviceDate": Self.serviceDate(date),
            "source": "app",
            "recordedVia": recordedVia,
            "outcome": "in_progress",
            "createdAt": FieldValue.serverTimestamp(),
            // Route Memory: which property this visit counts toward (the
            // customer, else the stop). The security rules check it.
            "propertyKey": RouteMemoryService.propertyKey(for: stop)
        ]
        if let uid = Auth.auth().currentUser?.uid { d["recordedBy"] = uid }
        // The run (this shift on this route) the visit belongs to.
        if let runId = RouteMemoryService.shared.currentRunId { d["runId"] = runId }
        if let routeName { d["routeName"] = routeName }
        if let v = stop.customerId { d["customerId"] = v }
        if let v = stop.customerName { d["customerName"] = v }
        if let v = stop.latitude { d["propertyLatitude"] = v }
        if let v = stop.longitude { d["propertyLongitude"] = v }
        if let driverId = stop.driverId {
            d["driverId"] = driverId
            if let me = DriverSession.shared.driver, me.id == driverId {
                d["driverName"] = me.name
            }
        }
        return d
    }

    private func fields(for event: Event, at date: Date, recordedVia: String) -> [String: Any] {
        let ts = Timestamp(date: date)
        switch event {
        case .enRoute:
            return ["enRouteAt": ts]
        case .arrived:
            return ["arrivedAt": ts]
        case .skipped:
            return ["skippedAt": ts, "outcome": "skipped"]
        case .completed:
            var d: [String: Any] = ["completedAt": ts, "outcome": "completed"]
            if recordedVia == "driver_app", let gps = Self.gpsAtDone(now: date) {
                d["completedLocation"] = gps
            } else {
                d["completedLocationMissing"] = recordedVia == "driver_app"
                    ? "No GPS fix on the phone when Done was tapped (location tracking was off or hadn't started)."
                    : "Marked done by the owner/manager from Edit Route - no truck position."
            }
            return d
        }
    }

    /// The truck's position at the moment Done was tapped - the
    /// phone's own last GPS fix, NOT the property's address pin. The
    /// fix's age is stored with it, so a stale position is visibly
    /// stale instead of passing as proof.
    private static func gpsAtDone(now: Date) -> [String: Any]? {
        let loc = LocationService.shared
        guard let coord = loc.currentLocation, let fixTime = loc.lastLocationUpdate else { return nil }
        var d: [String: Any] = [
            "latitude": coord.latitude,
            "longitude": coord.longitude,
            "fixAt": Timestamp(date: fixTime),
            "fixAgeSeconds": max(0, Int(now.timeIntervalSince(fixTime)))
        ]
        if let acc = loc.currentAccuracy { d["accuracyMeters"] = acc }
        return d
    }

    /// The company's local calendar day the visit started on - what an
    /// owner means by "the Nov 3 storm". Stored once, at creation, so an
    /// overnight run that finishes after midnight stays one visit.
    static func serviceDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let tzId = CompanySession.shared.currentCompany?.timeZoneIdentifier ?? "America/Toronto"
        f.timeZone = TimeZone(identifier: tzId) ?? .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
