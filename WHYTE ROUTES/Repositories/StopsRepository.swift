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
                    do {
                        return try doc.data(as: Stop.self)
                    } catch {
                        print("❌ [StopsRepository] Decoding error for stop \(doc.documentID):", error.localizedDescription)
                        return nil
                    }
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
            guard let id = stop.id else { continue }

            let stopRef = routeRef.collection("stops").document(id)

            do {
                try batch.setData(from: stop, forDocument: stopRef)
            } catch {
                print("❌ [StopsRepository] Encoding error for stop \(stop.id ?? "nil"):", error.localizedDescription)
            }
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

        guard let id = stop.id else {
            completion?(false)
            return
        }

        let stopRef = db.collection("routes")
            .document(routeId)
            .collection("stops")
            .document(id)

        do {
            try stopRef.setData(from: stop) { error in
                if let error = error {
                    print("❌ Failed updating stop:", error.localizedDescription)
                    completion?(false)
                } else {
                    completion?(true)
                }
            }
        } catch {
            print("❌ [StopsRepository] Encoding error for stop \(stop.id ?? "nil"):", error.localizedDescription)
            completion?(false)
        }
    }
}
