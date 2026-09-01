import Foundation
import FirebaseFirestore
import CoreLocation

/// What every driver-data backend must support.
protocol DriverRepository {
    func fetchDrivers(_ completion: @escaping (Result<[Driver], Error>) -> Void)
    func listenToDrivers(_ handler: @escaping ([Driver]) -> Void)
    func updateDriverLocation(driverId: String, latitude: Double, longitude: Double)
    func updateDriverName(driverId: String, name: String, completion: ((Bool) -> Void)?)
    func updateDriverVehicle(driverId: String, vehicle: String, completion: ((Bool) -> Void)?)
    func updateDriverPhone(driverId: String, phone: String, completion: ((Bool) -> Void)?)
    func updateLicensePhotoPath(driverId: String, path: String, completion: ((Bool) -> Void)?)
    func assignRoute(driverId: String, routeId: String)
    func fetchActiveShift(driverId: String, completion: @escaping (Shift?) -> Void)
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
            // uid here, and driver.id below, are Firebase uids, so
            // both are DEBUG-only. The two listener failures further
            // down name nobody and stay as plain print, so a field
            // report still carries them.
            safePrint("⚠️ FirestoreDriverRepository.fetchDriver(\(uid)) failed: \(error.localizedDescription)")
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
            safePrint("⚠️ FirestoreDriverRepository.createDriver(\(driver.id)) failed: \(error.localizedDescription)")
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

    // MARK: - Update Display Name
    // A driver's initial name defaults to their Firebase Auth
    // displayName, falling back to their email when that's empty (see
    // AuthSession.bridgeDriverSession) - a real, common case for
    // email/Apple ID sign-in, and exactly why this exists: without it
    // there was no way for an owner to fix a driver showing up as
    // their raw email address on the live fleet map.
    func updateDriverName(driverId: String, name: String, completion: ((Bool) -> Void)? = nil) {
        guard let ref = driversRef?.document(driverId) else { completion?(false); return }
        ref.updateData(["name": name]) { error in
            completion?(error == nil)
        }
    }

    // MARK: - Update Vehicle
    // The profile has always DISPLAYED a Vehicle row and never offered
    // any way to fill it, so every driver saw a permanently blank
    // field. It matters on a multi-truck crew - "which one is Devon
    // in" - so it is editable now rather than removed.
    func updateDriverVehicle(driverId: String, vehicle: String, completion: ((Bool) -> Void)? = nil) {
        guard let ref = driversRef?.document(driverId) else { completion?(false); return }
        ref.updateData(["vehicle": vehicle]) { error in
            completion?(error == nil)
        }
    }

    // MARK: - Update Phone
    // Exactly the same omission the Vehicle row had: the profile
    // DISPLAYED a Phone row and offered no way to fill it, so every
    // driver saw a permanent "N/A" beside a label that looked like it
    // should be editable. An owner needs a way to reach the person
    // driving their truck.
    //
    // An empty string DELETES the field rather than storing "", so
    // clearing the box actually clears the number instead of leaving
    // an empty string that reads as "set" to everything downstream.
    func updateDriverPhone(driverId: String, phone: String, completion: ((Bool) -> Void)? = nil) {
        guard let ref = driversRef?.document(driverId) else { completion?(false); return }
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        ref.updateData(["phone": trimmed.isEmpty ? FieldValue.delete() : trimmed]) { error in
            completion?(error == nil)
        }
    }

    // MARK: - Update License Photo Path
    // Path only, never a download URL - see Driver.licensePhotoPath.
    func updateLicensePhotoPath(driverId: String, path: String, completion: ((Bool) -> Void)? = nil) {
        guard let ref = driversRef?.document(driverId) else { completion?(false); return }
        ref.updateData(["licensePhotoPath": path]) { error in
            completion?(error == nil)
        }
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

    // MARK: - Fetch a Driver's Currently Active Shift
    // Powers the owner's driver-detail card on the fleet map ("Shift:
    // 5h 42m") - a driver's own shift lifecycle already writes here
    // (see ShiftRepository), this just reads it back for someone else
    // looking at that driver, not the driver's own session.
    func fetchActiveShift(driverId: String, completion: @escaping (Shift?) -> Void) {
        guard let ref = driversRef?.document(driverId).collection("shifts") else {
            completion(nil)
            return
        }
        ref.whereField("status", isEqualTo: "active")
            .limit(to: 1)
            .getDocuments { snapshot, error in
                guard error == nil, let doc = snapshot?.documents.first else {
                    completion(nil)
                    return
                }
                completion(Shift(from: doc.data(), id: doc.documentID))
            }
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
