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

    // MARK: - Fetch/Create the Signed-In Driver's Own Record
    // Used once, right after a real Firebase Auth sign-in resolves to
    // companyRole == "driver", to bridge into DriverSession. The
    // driver's own Firestore doc ID IS their Firebase Auth UID (not an
    // arbitrary ID an owner picks), matching the Firestore rule that
    // lets a driver create/update only the one doc whose ID is their
    // own uid.
    func fetchDriver(uid: String) async -> Driver? {
        guard let driversRef else { return nil }
        do {
            let snapshot = try await driversRef.document(uid).getDocument()
            guard let data = snapshot.data() else { return nil }
            return Driver(from: data, id: uid)
        } catch {
            print("⚠️ FirestoreDriverRepository.fetchDriver(\(uid)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func createDriver(_ driver: Driver) async -> Driver? {
        guard let driversRef else { return nil }
        do {
            try await driversRef.document(driver.id).setData(driver.toDict())
            return driver
        } catch {
            print("⚠️ FirestoreDriverRepository.createDriver(\(driver.id)) failed: \(error.localizedDescription)")
            return nil
        }
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
    // Field name must be "lastUpdated" - that's what Driver.init(from:)
    // actually decodes (see Models/Driver.swift), not "updatedAt".
    func updateDriverLocation(driverId: String,
                              latitude: Double,
                              longitude: Double) {

        driversRef?
            .document(driverId)
            .updateData([
                "latitude": latitude,
                "longitude": longitude,
                "lastUpdated": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Assign Driver to a Route
    // Field name must match Driver.activeRoute (see Models/Driver.swift) -
    // that's what DriverTabView/ManagerDriversView actually read.
    func assignRoute(driverId: String, routeId: String) {
        driversRef?
            .document(driverId)
            .updateData([
                "activeRoute": routeId,
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }

    /// Called on whichever driver a route is being taken AWAY from
    /// during reassignment, so their own activeRoute pointer doesn't
    /// keep referencing a route that's no longer theirs.
    func clearActiveRoute(driverId: String) {
        driversRef?
            .document(driverId)
            .updateData([
                "activeRoute": FieldValue.delete(),
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }
}
