import Foundation
import Combine
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
    private var isListeningLive = false

    // MARK: - Init
    init() {
        loadDrivers()
    }

    // MARK: - Load All Drivers (one-time - used by dashboards/reports/
    // lists that just need a current count or roster, not a live feed)
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

    // MARK: - Live Updates (used by LiveFleetMapView - driver dots need
    // to actually move as GPS pings arrive, not just show a snapshot
    // from whenever the screen happened to load)
    func startLiveUpdates() {
        guard !isListeningLive else { return }
        isListeningLive = true
        isLoading = true

        driverRepo.listenToDrivers { [weak self] drivers in
            Task { @MainActor in
                self?.drivers = drivers
                self?.isLoading = false
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
