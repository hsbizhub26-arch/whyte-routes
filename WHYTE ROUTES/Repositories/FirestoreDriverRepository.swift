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

    // MARK: - Fetch Drivers Once
    func fetchDrivers(_ completion: @escaping (Result<[Driver], Error>) -> Void) {
        db.collection("drivers")
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

    // MARK: - Listen to All Drivers (real-time updates)
    func listenToDrivers(_ handler: @escaping ([Driver]) -> Void) {
        db.collection("drivers")
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

        db.collection("drivers")
            .document(driverId)
            .updateData([
                "latitude": latitude,
                "longitude": longitude,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Assign Driver to a Route
    func assignRoute(driverId: String, routeId: String) {
        db.collection("drivers")
            .document(driverId)
            .updateData([
                "assignedRouteId": routeId,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }
}
