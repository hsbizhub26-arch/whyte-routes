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
    // One-shot per arrival target - see detectArrival. Reset whenever
    // setArrivalTarget points at a different stop.
    @Published var hasArrivedAtTarget = false

    // 40m rather than a tighter radius: a driveway, the truck parked
    // at the curb, and the GPS fix itself all sit a little apart, and
    // under-triggering (driver stands there and nothing happens) is a
    // worse failure than triggering a few metres early.
    private static let arrivalRadius: CLLocationDistance = 40
    // Fixes less accurate than this can't meaningfully be inside a
    // 40m circle, so they're ignored for geofencing.
    private static let maxUsableAccuracy: CLLocationAccuracy = 50

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
        // Only reset the geofence when the target actually moves to a
        // different place. This is called from onAppear too, so
        // resetting unconditionally would re-arm the geofence every
        // time the driver returned to a stop they'd already arrived
        // at, re-firing auto-arrival on a stop already in progress.
        let isSameTarget = (lat == stopLat && lng == stopLng)
        self.stopLat = lat
        self.stopLng = lng
        if !isSameTarget {
            hasArrivedAtTarget = false
        }
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

        detectArrival(at: location)
    }

    // MARK: - Detect Arrival (geofence)
    // Fires once per arrival target: flips to true the first time the
    // driver comes within arrivalRadius of the current stop, and is
    // reset by setArrivalTarget when the target changes. Whoever owns
    // the stop's status (DriverStopViewModel) observes this and makes
    // the actual transition - this stays a pure location concern and
    // doesn't reach up into view models or write to Firestore itself.
    private func detectArrival(at location: CLLocation) {
        guard !hasArrivedAtTarget,
              let sLat = stopLat, let sLng = stopLng else { return }

        // A fix the phone itself reports as poor (or invalid, which
        // CoreLocation signals with a negative value) must not trip a
        // geofence - a 200m-accurate fix "inside" a 40m radius means
        // nothing, and a false auto-arrival would stamp the wrong
        // arrivedAt and fire the customer's arrival text early.
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.maxUsableAccuracy else { return }

        let stop = CLLocation(latitude: sLat, longitude: sLng)
        if location.distance(from: stop) <= Self.arrivalRadius {
            hasArrivedAtTarget = true
            print("🎯 Geofence: arrived at stop (accuracy \(Int(location.horizontalAccuracy))m)")
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
