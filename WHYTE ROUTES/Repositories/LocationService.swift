import Foundation
import CoreLocation
import Combine
import UIKit

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
    static let maxUsableAccuracy: CLLocationAccuracy = 25

    private var driverId: String = ""
    private var stopLat: Double?
    private var stopLng: Double?
    /// Every other stop still on the route - see detectArrival.
    private var otherStopCoordinates: [CLLocationCoordinate2D] = []

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Tells CoreLocation this is a vehicle on roads: it snaps fixes
        // to the road network and filters the sideways wobble that made
        // the truck "jump around" on the Nov 3 test. It was never set,
        // so the default (.other) was being used.
        manager.activityType = .automotiveNavigation
        // 5m, not 20m. The 20m filter was one cause of the lag: below
        // ~25 km/h (residential streets, plowing a lot) a fix only
        // arrived every few seconds, and each one landed as a 20m hop.
        // The GPS chip runs at full accuracy either way, so this costs
        // almost no battery - and Firestore writes are throttled on
        // their own in didUpdateLocations, not by this number.
        manager.distanceFilter = Self.shiftDistanceFilter
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        // The blue pill in the status bar while tracking in the
        // background. Keeps iOS from treating an all-night "Always"
        // session as suspicious, and tells the driver it is running.
        manager.showsBackgroundLocationIndicator = true
    }

    private static let shiftDistanceFilter: CLLocationDistance = 5

    // MARK: - Firestore write throttle
    // Near-real-time without flooding Firestore. A write goes out when
    // the truck has moved a little AND a few seconds have passed, plus
    // a heartbeat while parked so the owner's map and the "10 minutes
    // away" check both know the phone is still alive.
    //   Driving 50 km/h: ~1 write / 3 s  (~1,200 writes per driving hour)
    //   Parked at a stop: 1 write / 30 s
    // An 8-hour shift is well under 10k writes - pennies, and far below
    // what Uber-style tracking spends.
    private static let minWriteInterval: TimeInterval = 3
    private static let minWriteDistance: CLLocationDistance = 8
    private static let heartbeatInterval: TimeInterval = 30
    /// A fix vaguer than this is never written. Those are the "jumps":
    /// one 80m-off fix in a tunnel, parking garage or under trees, then
    /// a snap back. Looser than maxUsableAccuracy (25m, arrival
    /// geofence) because a pin on a map tolerates more than "which
    /// house am I at" does.
    private static let maxWritableAccuracy: CLLocationAccuracy = 50
    private var lastWrittenAt: Date?

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
        lastWrittenLocation = nil
        lastWrittenAt = nil
        stopLat = nil
        stopLng = nil
        print("🛑 Location tracking stopped")
    }

    // MARK: - Navigation Mode
    // Full-screen turn-by-turn needs a fix on every GPS tick so the
    // camera glides with the vehicle the way Uber/Waze do - a 20m
    // filter reads as the map stuttering forward in lurches. The
    // Firestore write path is throttled separately (see
    // didUpdateLocations), so this only changes what the CAMERA sees,
    // not what the backend is billed for.
    /// Whether the compass may drive currentHeading - see
    /// didUpdateHeading. Only true while full-screen navigation is up;
    /// the fleet/customer pins outside navigation should keep pointing
    /// the way the truck was travelling, not the way the phone happens
    /// to be held in someone's hand.
    private var navigationModeActive = false
    /// Latest GPS ground speed (m/s, negative = unknown). Decides
    /// whether course or compass owns the heading.
    private var lastSpeed: CLLocationSpeed = -1

    func setNavigationMode(_ active: Bool) {
        navigationModeActive = active
        // 5m in and out of navigation now (see shiftDistanceFilter); the
        // old 20m outside navigation was part of the lag. The camera is
        // driven by its own 2Hz timer now, so it no longer needs a fix
        // on every GPS tick - and the unfiltered firehose was the lag:
        // every fix re-ran the whole navigation view's body, a Firestore
        // write, the arrival geofence and the customer-tracking publish.
        // 5m keeps following smooth at driving speed while cutting that
        // downstream work by an order of magnitude.
        manager.distanceFilter = Self.shiftDistanceFilter
        // The magnetometer heading is what turns the map when the
        // DRIVER turns, before the truck moves - GPS course only knows
        // a direction once there is actual travel. Google/Waze feel
        // "attached to the phone" because of exactly this source.
        if active {
            syncHeadingOrientation()
            manager.startUpdatingHeading()
        } else {
            manager.stopUpdatingHeading()
        }
        if active {
            // Navigation must not depend on the shift lifecycle having
            // started GPS - an owner trying the driver flow, or a driver
            // opening navigation before clocking in, otherwise gets a
            // camera with no fixes at all. Idempotent if already running,
            // and the Firestore write path stays driverId-gated, so this
            // publishes to the UI only.
            requestPermissions()
            manager.startUpdatingLocation()
        } else if driverId.isEmpty {
            // Only stop what navigation itself started - never the
            // tracker for an active shift.
            manager.stopUpdatingLocation()
        }
    }

    /// Where the last Firestore write happened, so navigation mode's
    /// per-tick fixes don't turn into per-tick billed writes.
    private var lastWrittenLocation: CLLocation?

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

        // CoreLocation hands back a CACHED fix first when updates start
        // - wherever the phone last was, possibly across town. Writing
        // it put the truck somewhere wrong for a few seconds and then
        // "teleported" it. Anything older than 10s is history, not a
        // live position. Invalid fixes (negative accuracy) go too.
        guard abs(location.timestamp.timeIntervalSinceNow) < 10,
              location.horizontalAccuracy >= 0 else { return }

        currentLocation = location.coordinate
        lastLocationUpdate = Date()
        // Negative course means CoreLocation couldn't determine a
        // direction (typically stationary) - keep the last known
        // heading rather than snapping the customer's map pin to
        // north every time the truck stops at a light.
        lastSpeed = location.speed
        // Above walking pace GPS course is the truth (it's where the
        // vehicle is actually going, phone orientation be damned);
        // below it the compass owns the heading in navigation mode -
        // see didUpdateHeading. Outside navigation, keep the old
        // behavior: course when known, last value otherwise.
        if location.course >= 0, !navigationModeActive || location.speed >= 2 {
            currentHeading = location.course
        }
        currentAccuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil

        guard !driverId.isEmpty else { return }
        detectArrival(at: location)

        // Throttled write - see minWriteInterval. Replaces a pure "20m
        // moved" rule, which had no clock in it: crawling along a street
        // it could go long stretches without writing, and parked at a
        // stop it NEVER wrote, so lastUpdated went stale and the server
        // refused the 10-minutes-away text as "gps_stale".
        guard location.horizontalAccuracy <= Self.maxWritableAccuracy else { return }
        let now = Date()
        if let last = lastWrittenLocation, let lastAt = lastWrittenAt {
            let elapsed = now.timeIntervalSince(lastAt)
            let moved = location.distance(from: last)
            let movedEnough = elapsed >= Self.minWriteInterval && moved >= Self.minWriteDistance
            let heartbeatDue = elapsed >= Self.heartbeatInterval
            guard movedEnough || heartbeatDue else { return }
        }
        lastWrittenLocation = location
        lastWrittenAt = now
        driverRepo.updateDriverLocation(
            driverId: driverId,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            heading: location.course >= 0 ? location.course : nil,
            speed: location.speed >= 0 ? location.speed : nil
        )
    }

    /// iPad only. CoreLocation measures compass heading from the top edge
    /// of the device held in PORTRAIT unless told otherwise, so on an iPad
    /// mounted in landscape the heading-up nav map was turned 90 degrees
    /// from the road whenever the compass owned the heading - every stop
    /// sign, and the whole drive on a Wi-Fi-only iPad, which has no GPS
    /// speed to hand the heading over to course. The customer's tracking
    /// pin inherits the same value. Called when navigation starts and on
    /// the navigation screen's 1Hz camera tick, which catches a rotation
    /// mid-drive. iPhone keeps the default .portrait, unchanged.
    func syncHeadingOrientation() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let orientation: CLDeviceOrientation
        switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        // Interface and device landscape are mirror images: the
        // interface is landscapeLeft when the DEVICE is landscapeRight.
        case .landscapeLeft: orientation = .landscapeRight
        case .landscapeRight: orientation = .landscapeLeft
        default: return  // .unknown - keep the last good value
        }
        if manager.headingOrientation != orientation {
            manager.headingOrientation = orientation
        }
    }

    // MARK: - Compass Heading (navigation mode only)
    // Turns the nav map with the phone while stationary or crawling,
    // exactly like Google Maps/Waze. Gated on navigationModeActive so
    // the fleet map and customer tracking pins never inherit "which way
    // the phone was facing in the cupholder."
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard navigationModeActive, newHeading.headingAccuracy >= 0, lastSpeed < 2 else { return }
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        // The magnetometer streams dozens of updates a second. Publishing
        // every one re-runs the whole navigation view's body that often
        // for sub-degree jitter nobody can see - a real frame-rate cost.
        // Only publish once the heading has actually moved a couple of
        // degrees, which is smooth to the eye and a fraction of the work.
        if let current = currentHeading {
            var delta = abs(heading - current).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta = 360 - delta }
            guard delta >= 2 else { return }
        }
        currentHeading = heading
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
