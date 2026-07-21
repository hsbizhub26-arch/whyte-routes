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

    // MARK: - Update Route Status
    func updateStatus(routeId: String, status: String) {
        routesRef?
            .document(routeId)
            .updateData([
                "status": status,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Assign Driver
    func assignDriver(routeId: String, driverId: String) {
        routesRef?
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
