import Foundation
import CoreLocation
import Combine

@MainActor
class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private let manager = CLLocationManager()
    private let driverRepo = FirestoreDriverRepository()

    @Published var currentLocation: CLLocationCoordinate2D?
    /// Degrees clockwise from true north, or nil until a direction of
    /// travel is known. Used to point the driver pin on the customer's
    /// tracking page the way the truck is actually facing.
    @Published var currentHeading: CLLocationDirection?
    /// Horizontal accuracy of the latest fix, in metres. Exposed
    /// because callers deciding whether a coordinate is safe to
    /// publish need to know how much to trust it - a fix vague to
    /// 150m can place the truck outside an exclusion zone it is
    /// physically sitting inside.
    @Published var currentAccuracy: CLLocationAccuracy?
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
    // Tight on purpose. Neighbouring houses are ~20m apart, so a fix
    // vague to 50m can rank the wrong one as nearest and arrive at the
    // neighbour. Typical open-sky accuracy is 5-15m, so this still
    // passes normally; under heavy tree cover it won't, and the driver
    // taps Arrived by hand. Under-triggering is a mild annoyance -
    // texting the wrong customer that their driveway is done is not.
    private static let maxUsableAccuracy: CLLocationAccuracy = 25

    private var driverId: String = ""
    private var stopLat: Double?
    private var stopLng: Double?
    /// Every other stop still on the route - see detectArrival.
    private var otherStopCoordinates: [CLLocationCoordinate2D] = []

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

        // The driver's uid, so DEBUG-only. "tracking stopped" below
        // names nobody and stays a plain print.
        safePrint("📡 Location tracking started for driver: \(driverId)")
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
    /// - Parameter otherStops: every OTHER stop still on this route.
    ///   Used to disambiguate neighbouring properties - see
    ///   detectArrival for why a plain radius check isn't enough.
    func setArrivalTarget(lat: Double?, lng: Double?, otherStops: [CLLocationCoordinate2D] = []) {
        // Only reset the geofence when the target actually moves to a
        // different place. This is called from onAppear too, so
        // resetting unconditionally would re-arm the geofence every
        // time the driver returned to a stop they'd already arrived
        // at, re-firing auto-arrival on a stop already in progress.
        let isSameTarget = (lat == stopLat && lng == stopLng)
        self.stopLat = lat
        self.stopLng = lng
        self.otherStopCoordinates = otherStops
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
        // Negative course means CoreLocation couldn't determine a
        // direction (typically stationary) - keep the last known
        // heading rather than snapping the customer's map pin to
        // north every time the truck stops at a light.
        if location.course >= 0 {
            currentHeading = location.course
        }
        currentAccuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil

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
        let distanceToTarget = location.distance(from: stop)
        guard distanceToTarget <= Self.arrivalRadius else { return }

        // Neighbouring properties: on a residential street houses sit
        // ~20m apart, well inside the arrival radius, so "am I within
        // 40m of the target" is true for three houses at once and
        // can't tell them apart. Worse, the driver standing at house 1
        // is already inside house 2's radius the instant house 2
        // becomes the target - which would mark house 2 arrived
        // without moving, text that customer, and (being one-shot)
        // then never fire when the driver actually got there.
        //
        // Ranking instead of thresholding fixes both: only arrive at
        // the target if it is genuinely the closest remaining stop.
        // Standing at house 1 with house 2 as the target, house 1 is
        // nearer, so nothing fires until the driver has actually
        // moved closer to house 2 than to house 1.
        for other in otherStopCoordinates {
            let otherLocation = CLLocation(latitude: other.latitude, longitude: other.longitude)
            if location.distance(from: otherLocation) < distanceToTarget { return }
        }

        hasArrivedAtTarget = true
        print("🎯 Geofence: arrived at stop (\(Int(distanceToTarget))m, accuracy \(Int(location.horizontalAccuracy))m)")
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
