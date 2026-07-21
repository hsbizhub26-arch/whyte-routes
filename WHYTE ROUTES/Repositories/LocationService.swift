import Foundation
import CoreLocation
import FirebaseFirestore
import Combine

@MainActor
class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private let manager = CLLocationManager()
    private let db = Firestore.firestore()

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
    func startTracking(driverId: String, stopLat: Double?, stopLng: Double?) {
        self.driverId = driverId
        self.stopLat = stopLat
        self.stopLng = stopLng

        requestPermissions()
        manager.startUpdatingLocation()

        print("📡 Location tracking started for driver:", driverId)
    }

    // MARK: - Stop Tracking
    func stopTracking() {
        manager.stopUpdatingLocation()
        print("🛑 Location tracking stopped")
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

        // Save to Firestore using correct fields for your Driver model
        db.collection("drivers")
            .document(driverId)
            .updateData([
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "lastUpdated": Timestamp(date: Date())
            ])

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
