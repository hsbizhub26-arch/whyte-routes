import Foundation
import FirebaseFirestore

final class RouteRepository {

    private let db = Firestore.firestore()

    /// Routes always live under the signed-in user's current company.
    /// Returns nil (and logs) if no company is set - callers treat
    /// that the same as "no results" rather than crashing.
    private var routesRef: CollectionReference? {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ RouteRepository: no current company set - cannot access routes")
            return nil
        }
        return db.collection("companies").document(companyId).collection("routes")
    }

    // MARK: - Load All Routes (live updates)
    func listenToRoutes(_ handler: @escaping ([Route]) -> Void) {
        guard let routesRef else { handler([]); return }

        routesRef
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { snapshot, error in

                guard error == nil else {
                    print("❌ Failed to listen to routes:", error?.localizedDescription ?? "")
                    handler([])
                    return
                }

                let routes: [Route] = snapshot?.documents.compactMap { doc in
                    Route(from: doc.data(), id: doc.documentID)
                } ?? []

                handler(routes)
            }
    }

    // MARK: - Load Once
    func fetchRoutes(completion: @escaping ([Route]) -> Void) {
        guard let routesRef else { completion([]); return }

        routesRef
            .order(by: "createdAt", descending: false)
            .getDocuments { snapshot, error in

                guard error == nil else {
                    print("❌ Failed to fetch routes:", error?.localizedDescription ?? "")
                    completion([])
                    return
                }

                let routes: [Route] = snapshot?.documents.compactMap { doc in
                    Route(from: doc.data(), id: doc.documentID)
                } ?? []

                completion(routes)
            }
    }

    // MARK: - Fetch Current Route for a Driver
    func fetchRouteForDriver(driverId: String, completion: @escaping (Route?) -> Void) {
        guard let routesRef else { completion(nil); return }

        routesRef
            .whereField("driverId", isEqualTo: driverId)
            .whereField("status", isNotEqualTo: "completed")
            .limit(to: 1)
            .getDocuments { snapshot, error in

                guard error == nil else {
                    print("❌ Failed to fetch route for driver:", error?.localizedDescription ?? "")
                    completion(nil)
                    return
                }

                guard let doc = snapshot?.documents.first else {
                    completion(nil)
                    return
                }

                completion(Route(from: doc.data(), id: doc.documentID))
            }
    }

    // MARK: - Fetch a Single Route
    func fetchRoute(routeId: String, completion: @escaping (Route?) -> Void) {
        guard let ref = routesRef?.document(routeId) else { completion(nil); return }
        ref.getDocument { snapshot, error in
            guard error == nil, let data = snapshot?.data() else {
                completion(nil)
                return
            }
            completion(Route(from: data, id: routeId))
        }
    }

    // MARK: - Rename / Reassign an Existing Route
    // Start/end fields use FieldValue.delete() when nil rather than
    // omitting them, so clearing a previously-set custom start or end
    // point (going back to "first/last stop is the endpoint") actually
    // removes the stale value instead of leaving it stranded in
    // Firestore where it'd keep being read back.
    func updateRoute(
        routeId: String,
        name: String,
        driverId: String?,
        startAddress: String? = nil,
        startLatitude: Double? = nil,
        startLongitude: Double? = nil,
        endAddress: String? = nil,
        endLatitude: Double? = nil,
        endLongitude: Double? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let ref = routesRef?.document(routeId) else { completion?(false); return }

        var data: [String: Any] = [
            "name": name,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        data["driverId"] = driverId ?? ""
        data["startAddress"] = startAddress ?? FieldValue.delete()
        data["startLatitude"] = startLatitude ?? FieldValue.delete()
        data["startLongitude"] = startLongitude ?? FieldValue.delete()
        data["endAddress"] = endAddress ?? FieldValue.delete()
        data["endLatitude"] = endLatitude ?? FieldValue.delete()
        data["endLongitude"] = endLongitude ?? FieldValue.delete()

        ref.updateData(data) { error in
            if let error = error {
                print("❌ Failed updating route:", error.localizedDescription)
                completion?(false)
            } else {
                completion?(true)
            }
        }
    }

    // MARK: - Update Route Status
    // No completion handler previously meant a permission-denied write
    // here (e.g. the Firestore-rules gap that let this silently fail
    // for real driver accounts) would never surface anywhere, not even
    // a console log - the driver just had no idea their route never
    // actually got marked completed.
    func updateStatus(routeId: String, status: String) {
        routesRef?
            .document(routeId)
            .updateData([
                "status": status,
                "updatedAt": FieldValue.serverTimestamp()
            ]) { error in
                if let error {
                    print("❌ Failed updating route status (\(routeId) -> \(status)): \(error.localizedDescription)")
                }
            }
    }

    // MARK: - Assign Driver
    // Writes the driver onto the route AND onto every one of its stops,
    // in one batch.
    //
    // The stops half is not bookkeeping. A driver's stop list is read
    // with `whereField("driverId", isEqualTo: uid)`, because the rules
    // only ever let them read their own - so a stop whose driverId
    // still names the previous driver (or is empty, on a route built
    // before anyone was assigned) is invisible to the person who is
    // supposed to service it. Assigning from the Manager screen used
    // to update the route alone, and the newly-assigned driver opened
    // the app to an empty route with nothing anywhere explaining why.
    //
    // Done here rather than in the call sites so all three of them -
    // the manager sheet, RouteService, and RouteViewModel - get it
    // without each having to remember.
    func assignDriver(routeId: String, driverId: String, completion: ((Bool) -> Void)? = nil) {
        guard let ref = routesRef?.document(routeId) else { completion?(false); return }

        ref.collection("stops").getDocuments { [weak self] snapshot, error in
            guard let self else { completion?(false); return }
            if let error {
                print("❌ Failed reading stops while assigning driver (\(routeId)): \(error.localizedDescription)")
                completion?(false)
                return
            }

            let batch = self.db.batch()
            batch.updateData([
                "driverId": driverId,
                "status": "assigned",
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: ref)

            for doc in snapshot?.documents ?? [] {
                batch.updateData(["driverId": driverId], forDocument: doc.reference)
            }

            batch.commit { error in
                if let error {
                    print("❌ Failed assigning driver (\(routeId) -> \(driverId)): \(error.localizedDescription)")
                }
                completion?(error == nil)
            }
        }
    }

    // MARK: - Create New Route
    func createRoute(name: String,
                     driverId: String? = nil,
                     completion: @escaping (String?) -> Void) {

        guard let doc = routesRef?.document() else { completion(nil); return }

        let data: [String: Any] = [
            "name": name,
            "driverId": driverId ?? "",
            "status": "pending",
            "createdAt": FieldValue.serverTimestamp()
        ]

        doc.setData(data) { error in
            if let error = error {
                print("❌ Failed creating route:", error.localizedDescription)
                completion(nil)
                return
            }

            completion(doc.documentID)
        }
    }
}
