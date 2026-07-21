import Foundation
import FirebaseFirestore
import CoreLocation

/// What every driver-data backend must support.
protocol DriverRepository {
    func fetchDrivers(_ completion: @escaping (Result<[Driver], Error>) -> Void)
    func listenToDrivers(_ handler: @escaping ([Driver]) -> Void)
    func updateDriverLocation(driverId: String, latitude: Double, longitude: Double)
    func assignRoute(driverId: String, routeId: String)
}

/// Firestore implementation for all DriverRepository actions.
final class FirestoreDriverRepository: DriverRepository {

    private let db = Firestore.firestore()

    /// Drivers always live under the signed-in user's current company.
    /// nil (logged) if no company is set.
    private var driversRef: CollectionReference? {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ FirestoreDriverRepository: no current company set - cannot access drivers")
            return nil
        }
        return db.collection("companies").document(companyId).collection("drivers")
    }

    // MARK: - Fetch Drivers Once
    func fetchDrivers(_ completion: @escaping (Result<[Driver], Error>) -> Void) {
        guard let driversRef else { completion(.success([])); return }

        driversRef
            .getDocuments { snapshot, error in

                if let error = error {
                    completion(.failure(error))
                    return
                }

                let drivers: [Driver] = snapshot?.documents.compactMap { doc in
                    Driver(from: doc.data(), id: doc.documentID)
                } ?? []

                completion(.success(drivers))
            }
    }

    // MARK: - Live-listen to a Single Driver by explicit company
    // (unauthenticated customer tracking - there's no signed-in
    // session/CompanySession here, the company comes from the
    // tracking link's URL instead). A listener, not a one-time fetch,
    // so the customer's map actually updates as the driver moves.
    func listenToDriver(companyId: String, driverId: String, handler: @escaping (Driver?) -> Void) {
        db.collection("companies").document(companyId).collection("drivers")
            .document(driverId)
            .addSnapshotListener { snapshot, error in
                guard error == nil, let data = snapshot?.data() else {
                    handler(nil)
                    return
                }
                handler(Driver(from: data, id: driverId))
            }
    }

    // MARK: - Listen to All Drivers (real-time updates)
    func listenToDrivers(_ handler: @escaping ([Driver]) -> Void) {
        guard let driversRef else { handler([]); return }

        driversRef
            .addSnapshotListener { snapshot, error in

                guard error == nil else {
                    print("❌ Failed to listen to drivers:", error?.localizedDescription ?? "")
                    handler([])
                    return
                }

                let drivers: [Driver] = snapshot?.documents.compactMap { doc in
                    Driver(from: doc.data(), id: doc.documentID)
                } ?? []

                handler(drivers)
            }
    }

    // MARK: - Update Live GPS
    func updateDriverLocation(driverId: String,
                              latitude: Double,
                              longitude: Double) {

        driversRef?
            .document(driverId)
            .updateData([
                "latitude": latitude,
                "longitude": longitude,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Assign Driver to a Route
    func assignRoute(driverId: String, routeId: String) {
        driversRef?
            .document(driverId)
            .updateData([
                "assignedRouteId": routeId,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }
}
