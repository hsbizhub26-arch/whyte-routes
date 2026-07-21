import Foundation
import FirebaseFirestore

final class StopsRepository {

    private let db = Firestore.firestore()

    // MARK: - Load Stops (Subcollection)
    func loadStops(forRoute routeId: String, completion: @escaping ([Stop]) -> Void) {

        db.collection("routes")
            .document(routeId)
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

        let routeRef = db.collection("routes").document(routeId)
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

        let stopRef = db.collection("routes")
            .document(routeId)
            .collection("stops")
            .document(stop.id)

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
