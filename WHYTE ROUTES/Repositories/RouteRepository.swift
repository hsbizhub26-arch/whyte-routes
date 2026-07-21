import Foundation
import FirebaseFirestore

final class RouteRepository {

    private let db = Firestore.firestore()

    // MARK: - Load All Routes (live updates)
    func listenToRoutes(_ handler: @escaping ([Route]) -> Void) {
        db.collection("routes")
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { snapshot, error in

                guard error == nil else {
                    print("❌ Failed to listen to routes:", error?.localizedDescription ?? "")
                    handler([])
                    return
                }

                let routes: [Route] = snapshot?.documents.compactMap { doc in
                    try? doc.data(as: Route.self)
                } ?? []

                handler(routes)
            }
    }

    // MARK: - Load Once
    func fetchRoutes(completion: @escaping ([Route]) -> Void) {
        db.collection("routes")
            .order(by: "createdAt", descending: false)
            .getDocuments { snapshot, error in

                guard error == nil else {
                    print("❌ Failed to fetch routes:", error?.localizedDescription ?? "")
                    completion([])
                    return
                }

                let routes: [Route] = snapshot?.documents.compactMap { doc in
                    try? doc.data(as: Route.self)
                } ?? []

                completion(routes)
            }
    }

    // MARK: - Update Route Status
    func updateStatus(routeId: String, status: String) {
        db.collection("routes")
            .document(routeId)
            .updateData([
                "status": status,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Assign Driver
    func assignDriver(routeId: String, driverId: String) {
        db.collection("routes")
            .document(routeId)
            .updateData([
                "driverId": driverId,
                "status": "assigned",
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Create New Route
    func createRoute(name: String,
                     driverId: String? = nil,
                     completion: @escaping (String?) -> Void) {

        let doc = db.collection("routes").document()

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
