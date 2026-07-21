class DriverLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.startUpdatingLocation()
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {

        guard let driverId = DriverSession.shared.driver?.id else { return }
        guard let loc = locations.last else { return }

        Firestore.firestore().collection("driverLocations").document(driverId).setData([
            "lat": loc.coordinate.latitude,
            "lng": loc.coordinate.longitude,
            "timestamp": Date().timeIntervalSince1970
        ])
    }
}
