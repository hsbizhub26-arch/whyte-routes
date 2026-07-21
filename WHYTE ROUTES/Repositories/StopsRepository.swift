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
}
