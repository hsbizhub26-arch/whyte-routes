import Foundation
import CoreLocation

@MainActor
final class DriverViewModel: ObservableObject {

    // MARK: - Published Properties
    @Published private(set) var drivers: [Driver] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Dependencies
    private let driverRepo: DriverRepository = FirestoreDriverRepository()
    private let locationManager = RealtimeLocationManager()

    // MARK: - Init
    init() {
        loadDrivers()
    }

    // MARK: - Load All Drivers
    func loadDrivers() {
        isLoading = true
        errorMessage = nil

        driverRepo.fetchDrivers { result in
            Task { @MainActor in
                switch result {
                case .success(let drivers):
                    self.drivers = drivers
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }

                self.isLoading = false
            }
        }
    }

    // MARK: - Update Live Driver Location
    func updateDriverLocation(driverId: String, coordinate: CLLocationCoordinate2D) {
        driverRepo.updateDriverLocation(
            driverId: driverId,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    // MARK: - Start GPS Tracking
    func startTracking(driverId: String, routeId: String) {
        locationManager.startUpdating(driverId: driverId, routeId: routeId)
    }

    // MARK: - Stop GPS Tracking
    func stopTracking() {
        locationManager.stopUpdating()
    }
}
