import Foundation
import FirebaseFirestore

final class StopsRepository {

    private let db = Firestore.firestore()

    /// A route's document reference within the current company. nil
    /// (logged) if no company is set.
    private func routeRef(_ routeId: String) -> DocumentReference? {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ StopsRepository: no current company set - cannot access stops")
            return nil
        }
        return db.collection("companies").document(companyId).collection("routes").document(routeId)
    }

    // MARK: - Load One Driver's Stops (driver app)
    //
    // Separate from the staff query below, and not an optimisation -
    // the unfiltered one CANNOT SUCCEED for a driver at all.
    //
    // The stops read rule grants staff everything, and otherwise only
    // documents where driverId == request.auth.uid. Firestore evaluates
    // a list query against the QUERY, not the results: it will not run
    // one that could return a document the rules would refuse, so an
    // unfiltered listen is denied outright rather than filtered down.
    // Every real driver therefore got permission-denied for their whole
    // route, which loadStops turned into an empty array, which the
    // dashboard rendered as "Route Completed 🎉 / All stops finished."
    // on a route they had not started. Owner-operators never saw it,
    // because an owner passes isCompanyStaff and gets the staff branch.
    //
    // Ordering is done in Swift rather than with .order(by: "order"),
    // because an equality filter plus an orderBy on a different field
    // needs a composite index this project has no index config to
    // declare. A route is tens of stops; sorting locally is free.
    //
    // The uid comes from Auth rather than DriverSession.driver?.id so
    // it is literally the value the rule compares against - those are
    // the same today, and a silent divergence would look exactly like
    // "the driver has no stops."
    func loadStops(forRoute routeId: String,
                   assignedTo driverUID: String,
                   completion: @escaping (Result<[Stop], Error>) -> Void) {
        guard let routeRef = routeRef(routeId) else {
            completion(.failure(StopsError.noCompanySelected))
            return
        }

        routeRef
            .collection("stops")
            .whereField("driverId", isEqualTo: driverUID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    // Deliberately NOT collapsed into an empty array.
                    // "I couldn't read your route" and "your route is
                    // finished" are opposite messages, and this used to
                    // send the second one.
                    print("❌ Failed to load driver stops:", error.localizedDescription)
                    let nsError = error as NSError
                    let denied = nsError.domain == FirestoreErrorDomain
                        && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
                    completion(.failure(denied ? StopsError.permissionDenied : error))
                    return
                }

                let stops = (snapshot?.documents ?? [])
                    .compactMap { Stop(from: $0.data(), id: $0.documentID) }
                    .sorted { $0.order < $1.order }

                completion(.success(stops))
            }
    }

    // MARK: - Save Route-Editor Edits (owner/manager)
    //
    // Writes ONLY the fields the route editor actually owns. It must
    // never send isCompleted, isSkipped, status, or the enRouteAt/
    // arrivedAt/completedAt timestamps, because those belong to the
    // driver and change while the editor is open.
    //
    // EditRouteView freezes its stop array at first load, deliberately,
    // so the form doesn't reshuffle under the owner mid-edit. Writing
    // that whole frozen array back is what made it destructive: an
    // owner who opened Edit Route at 6am and saved at 7am reverted
    // every stop the crew had completed in between to "scheduled" and
    // deleted the three timestamps outright - which are the entire
    // basis of the driver time report. Editing a live route is the
    // normal snow-ops workflow, not an edge case.
    //
    // Nil is written as an explicit delete rather than omitted, so that
    // clearing a customer's phone number in the editor actually clears
    // it instead of silently keeping the old value.
    func saveRouteEdits(forRoute routeId: String,
                        stops: [Stop],
                        completion: ((Bool) -> Void)? = nil) {

        guard let routeRef = routeRef(routeId) else { completion?(false); return }
        let batch = db.batch()

        for stop in stops {
            let stopRef = routeRef.collection("stops").document(stop.id)

            var data: [String: Any] = [
                "order": stop.order,
                "address": stop.address,
                "customerOptedIn": stop.customerOptedIn
            ]
            func put(_ key: String, _ value: Any?) {
                data[key] = value ?? FieldValue.delete()
            }
            put("driverId", stop.driverId)
            put("customerId", stop.customerId)
            put("customerName", stop.customerName)
            put("customerPhone", stop.customerPhone)
            put("customerEmail", stop.customerEmail)
            put("driverNotes", stop.driverNotes)
            put("latitude", stop.latitude)
            put("longitude", stop.longitude)

            batch.setData(data, forDocument: stopRef, merge: true)
        }

        batch.commit { error in
            if let error {
                print("❌ Failed saving route edits:", error.localizedDescription)
            }
            completion?(error == nil)
        }
    }

    enum StopsError: LocalizedError {
        case noCompanySelected
        /// Firestore refused the read. Classified HERE rather than in
        /// the view model so that Firestore stays behind the
        /// repository boundary - DriverSession needs to know a denial
        /// happened, not which SDK reported it.
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noCompanySelected:
                return "No company is selected for this account."
            case .permissionDenied:
                return "You don't have permission to read this route yet."
            }
        }
    }

    // MARK: - Load Stops (Subcollection)
    // STAFF ONLY - see the driver-scoped variant above for why this
    // one is denied for a driver account.
    func loadStops(forRoute routeId: String, completion: @escaping ([Stop]) -> Void) {
        guard let routeRef = routeRef(routeId) else { completion([]); return }

        routeRef
            .collection("stops")
            .order(by: "order")
            .addSnapshotListener { snapshot, error in

                guard error == nil else {
                    print("❌ Failed to load stops:", error?.localizedDescription ?? "")
                    completion([])
                    return
                }

                let stops: [Stop] = snapshot?.documents.compactMap { doc in
                    Stop(from: doc.data(), id: doc.documentID)
                } ?? []

                completion(stops)
            }
    }

    // MARK: - Save Stops (used for reordering, status toggle, etc.)
    func saveStops(forRoute routeId: String,
                   stops: [Stop],
                   completion: ((Bool) -> Void)? = nil) {

        guard let routeRef = routeRef(routeId) else { completion?(false); return }
        let batch = db.batch()

        for stop in stops {
            let stopRef = routeRef.collection("stops").document(stop.id)
            // merge: true because toDict() omits nil optionals, and a
            // plain setData treats "absent" as "delete". Any field the
            // caller's copy of the Stop happened not to carry was being
            // erased server-side on every write.
            batch.setData(stop.toDict(), forDocument: stopRef, merge: true)
        }

        batch.commit { error in
            if let error = error {
                print("❌ Failed saving stops:", error.localizedDescription)
                completion?(false)
                return
            }

            completion?(true)
        }
    }

    // MARK: - Update Single Stop
    func updateStop(routeId: String,
                    stop: Stop,
                    completion: ((Bool) -> Void)? = nil) {

        guard let stopRef = routeRef(routeId)?.collection("stops").document(stop.id) else {
            completion?(false)
            return
        }

        // merge: true for the same reason as saveStops - toDict() omits
        // nil optionals and a plain setData reads absence as deletion.
        // This is the driver's En Route / Arrived / Completed path, so
        // it runs several times per stop, every stop, all shift.
        //
        // It also keeps the write honest for the rules: the driver
        // branch now permits only the keys that recording their own
        // work touches, and that is judged on what actually CHANGED.
        // Without merge, every field the local Stop happened not to
        // carry would count as a deletion, and the whole write would be
        // refused.
        stopRef.setData(stop.toDict(), merge: true) { error in
            if let error = error {
                print("❌ Failed updating stop:", error.localizedDescription)
                completion?(false)
            } else {
                completion?(true)
            }
        }
    }

    // MARK: - Delete Single Stop (removed while editing a route)
    func deleteStop(routeId: String,
                    stopId: String,
                    completion: ((Bool) -> Void)? = nil) {

        guard let stopRef = routeRef(routeId)?.collection("stops").document(stopId) else {
            completion?(false)
            return
        }

        stopRef.delete { error in
            if let error = error {
                print("❌ Failed deleting stop:", error.localizedDescription)
                completion?(false)
            } else {
                completion?(true)
            }
        }
    }

    // MARK: - Move a Stop Between Routes (live reassignment - e.g. a
    // driver finished early and can pick up work from someone still
    // behind, or a stop needs pulling off a route it doesn't belong
    // on). Atomic: removal from the source route and the add to the
    // target route happen in one batch, so the stop is never briefly
    // missing from both if the write is interrupted. Appended to the
    // end of the target route's order, not kept at its old position,
    // since that position belongs to a different route's numbering.
    func moveStop(_ stop: Stop,
                  fromRouteId: String,
                  toRouteId: String,
                  newDriverId: String?,
                  completion: ((Bool) -> Void)? = nil) {

        guard let sourceRef = routeRef(fromRouteId)?.collection("stops").document(stop.id),
              let targetCollection = routeRef(toRouteId)?.collection("stops") else {
            completion?(false)
            return
        }

        targetCollection.getDocuments { snapshot, error in
            if let error {
                print("❌ Failed moving stop (couldn't read target route): \(error.localizedDescription)")
                completion?(false)
                return
            }

            var movedStop = stop
            movedStop.driverId = newDriverId
            movedStop.order = snapshot?.documents.count ?? 0

            let targetRef = targetCollection.document(stop.id)
            let batch = self.db.batch()
            batch.deleteDocument(sourceRef)
            batch.setData(movedStop.toDict(), forDocument: targetRef)

            batch.commit { error in
                if let error {
                    print("❌ Failed moving stop: \(error.localizedDescription)")
                    completion?(false)
                } else {
                    completion?(true)
                }
            }
        }
    }
}
