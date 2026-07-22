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

    // MARK: - Load Stops (Subcollection)
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
            batch.setData(stop.toDict(), forDocument: stopRef)
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

        stopRef.setData(stop.toDict()) { error in
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
