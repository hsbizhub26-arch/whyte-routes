import Foundation
import CoreLocation
import Combine

@MainActor
class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private let manager = CLLocationManager()
    private let driverRepo = FirestoreDriverRepository()

    @Published var currentLocation: CLLocationCoordinate2D?
    // When currentLocation was actually set, not just the last time
    // this object was asked - what ETA-notification staleness checks
    // compare against, so a phone with no signal for the last 20
    // minutes doesn't get treated as "still right here."
    @Published var lastLocationUpdate: Date?
    // Set the moment permission is revoked (Settings app, or denied
    // outright) or a fix genuinely can't be obtained - the driver UI
    // can surface this instead of silently tracking nothing for the
    // rest of a shift. nil means "no known problem," not "confirmed
    // working" - a phone with no signal briefly is normal and doesn't
    // set this.
    @Published var trackingError: String?

    private var driverId: String = ""
    private var stopLat: Double?
    private var stopLng: Double?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Without this, CoreLocation reports on essentially every GPS
        // tick - a real battery and Firestore-write cost over an
        // overnight shift, with no map/ETA benefit: a vehicle moving
        // 20m hasn't meaningfully changed which stop it's near.
        manager.distanceFilter = 20
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
        lastLocationUpdate = Date()

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
    // Distinguishes a transient miss (no fix yet, briefly indoors/in a
    // dead zone - CoreLocation keeps trying on its own, nothing for
    // the driver to act on) from something that actually needs
    // surfacing. A silent console print was the whole problem: a
    // driver had no way to know GPS had genuinely stopped working
    // partway through a shift.
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ Location Error:", error.localizedDescription)
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return
        }
        trackingError = "Location tracking stopped working: \(error.localizedDescription)"
    }

    // MARK: - Authorization Changes
    // Catches a driver revoking permission mid-shift (Settings app,
    // accidental tap) - without this, tracking just silently stops
    // with no signal anywhere in the app that it happened.
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .denied, .restricted:
            trackingError = "Location access was turned off - customer ETA updates and the live fleet map won't work until it's re-enabled in Settings."
        case .authorizedAlways, .authorizedWhenInUse:
            trackingError = nil
        default:
            break
        }
    }
}
