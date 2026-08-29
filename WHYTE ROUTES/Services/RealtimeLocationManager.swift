import Combine
import Foundation
import CoreLocation
import FirebaseFirestore

/// Handles driver real-time GPS location updates.
/// Publishes coordinate changes and optionally syncs to Firestore.
final class RealtimeLocationManager: NSObject, ObservableObject {

    // Published location + coordinate for SwiftUI Map
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var lastCoordinate: CLLocationCoordinate2D?

    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager: CLLocationManager
    private var cancellables = Set<AnyCancellable>()

    // Firestore reference for syncing driver live location
    private let db = Firestore.firestore()

    // Optional identifiers for syncing
    private var activeDriverId: String?
    private var activeRouteId: String?

    override init() {
        self.manager = CLLocationManager()
        self.authorizationStatus = manager.authorizationStatus
        super.init()

        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyBest
        self.manager.distanceFilter = 5 // meters
    }

    // MARK: - Permission Handling
    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - Start Updates
    func startUpdating(driverId: String? = nil, routeId: String? = nil) {
        self.activeDriverId = driverId
        self.activeRouteId = routeId

        guard CLLocationManager.locationServicesEnabled() else { return }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    // MARK: - Stop Updates
    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    // MARK: - Firestore Sync
    private func syncLocationToFirestore(_ coordinate: CLLocationCoordinate2D) {
        guard
            let driverId = activeDriverId,
            let routeId = activeRouteId
        else { return }

        db.collection("routes")
            .document(routeId)
            .collection("driversLive")
            .document(driverId)
            .setData([
                "lat": coordinate.latitude,
                "lng": coordinate.longitude,
                "timestamp": Date().timeIntervalSince1970
            ], merge: true)
    }
}

extension RealtimeLocationManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        self.authorizationStatus = manager.authorizationStatus

        // Deliberately does NOT start updating here.
        //
        // This fires whenever the delegate is assigned, which happens on
        // every launch - so simply having granted location once started
        // a kCLLocationAccuracyBest session on an owner's or manager's
        // phone that nothing read and nothing ever stopped, for as long
        // as the app was alive. Real GPS work is tied to the shift
        // lifecycle in LocationService (see DriverSession.startShift);
        // this class only ever mirrors it.
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }

        self.lastLocation = latest
        self.lastCoordinate = latest.coordinate

        // Sync to Firestore for tracking links + dispatch dashboard
        syncLocationToFirestore(latest.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        #if DEBUG
        print("[RealtimeLocation] Error: \(error.localizedDescription)")
        #endif
    }
}
