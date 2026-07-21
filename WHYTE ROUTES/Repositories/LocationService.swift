import Foundation
import CoreLocation
import Combine

@MainActor
class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private let manager = CLLocationManager()
    private let driverRepo = FirestoreDriverRepository()

    @Published var currentLocation: CLLocationCoordinate2D?

    private var driverId: String = ""
    private var stopLat: Double?
    private var stopLng: Double?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Start Tracking
    // Tied to the driver's shift lifecycle (see DriverSession.startShift) -
    // GPS should only run while a driver is actually on shift, not just
    // because a screen happened to appear.
    func startTracking(driverId: String) {
        self.driverId = driverId

        requestPermissions()
        manager.startUpdatingLocation()

        print("📡 Location tracking started for driver:", driverId)
    }

    // MARK: - Stop Tracking
    func stopTracking() {
        manager.stopUpdatingLocation()
        driverId = ""
        stopLat = nil
        stopLng = nil
        print("🛑 Location tracking stopped")
    }

    // MARK: - Arrival Detection Target
    // Set/cleared independently of start/stop tracking so opening a
    // specific stop doesn't restart the location manager - it just
    // tells an already-running tracker what "arrived" means right now.
    func setArrivalTarget(lat: Double?, lng: Double?) {
        self.stopLat = lat
        self.stopLng = lng
    }

    // MARK: - Location Permission Handler
    private func requestPermissions() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            break
        default:
            print("⚠️ Location permissions not granted.")
        }
    }

    // MARK: - Location Updates
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        currentLocation = location.coordinate

        guard !driverId.isEmpty else { return }
        driverRepo.updateDriverLocation(
            driverId: driverId,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )

        detectArrival(at: location.coordinate)
    }

    // MARK: - Detect Arrival
    private func detectArrival(at coord: CLLocationCoordinate2D) {
        guard let sLat = stopLat, let sLng = stopLng else { return }

        let driver = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let stop = CLLocation(latitude: sLat, longitude: sLng)

        if driver.distance(from: stop) < 30 {
            print("🎯 Driver Arrived at stop!")
        }
    }

    // MARK: - Error Handling
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ Location Error:", error.localizedDescription)
    }
}
