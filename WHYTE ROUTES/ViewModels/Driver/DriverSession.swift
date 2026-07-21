import Foundation
import Combine
import CoreLocation

@MainActor
final class DriverSession: ObservableObject {

    static let shared = DriverSession()
    private init() {}

    @Published var driver: Driver?
    @Published var assignedRoute: Route?
    @Published var activeStops: [Stop] = []
    @Published var activeShift: Shift?

    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()
    private let shiftRepo = ShiftRepository()

    // MARK: Load driver after login
    func setDriver(_ driver: Driver) {
        self.driver = driver
        loadAssignedRoute()
        Task { await restoreActiveShift() }
    }

    // MARK: Refresh current driver's route/stops (called when the tab view appears)
    func refresh() {
        loadAssignedRoute()
    }

    // MARK: Log out (clears local driver session state)
    func logout() {
        driver = nil
        assignedRoute = nil
        activeStops = []
        activeShift = nil
    }

    // MARK: - Shift start/end
    // Restores an already-active shift (e.g. app was killed mid-shift)
    // so Start Shift doesn't silently open a second, orphaned shift -
    // and resumes GPS tracking, since it doesn't survive a relaunch on
    // its own (CLLocationManager isn't restarted automatically here).
    private func restoreActiveShift() async {
        guard let driverId = driver?.id else { return }
        activeShift = await shiftRepo.fetchActiveShift(driverId: driverId)
        if activeShift != nil {
            LocationService.shared.startTracking(driverId: driverId)
        }
    }

    @discardableResult
    func startShift() async -> Bool {
        guard let driverId = driver?.id, activeShift == nil else { return false }
        if let shift = await shiftRepo.startShift(driverId: driverId) {
            activeShift = shift
            LocationService.shared.startTracking(driverId: driverId)
            return true
        }
        return false
    }

    @discardableResult
    func endShift() async -> Bool {
        guard let driverId = driver?.id, let shift = activeShift else { return false }
        let success = await shiftRepo.endShift(driverId: driverId, shiftId: shift.id)
        if success {
            activeShift = nil
            LocationService.shared.stopTracking()
        }
        return success
    }

    // MARK: Load assigned route
    func loadAssignedRoute() {
        guard let id = driver?.id else { return }

        routeRepo.fetchRouteForDriver(driverId: id) { route in
            Task { @MainActor in
                self.assignedRoute = route
                if let route = route {
                    self.loadStops(routeId: route.id)
                }
            }
        }
    }

    // MARK: Load a specific route by id (used to restore an active route on relaunch)
    func loadAssignedRoute(routeId: String) async {
        guard let id = driver?.id else { return }
        routeRepo.fetchRouteForDriver(driverId: id) { route in
            Task { @MainActor in
                self.assignedRoute = route
                if let route = route {
                    self.loadStops(routeId: route.id)
                }
            }
        }
    }

    // MARK: Load stops
    func loadStops(routeId: String) {
        stopsRepo.loadStops(forRoute: routeId) { stops in
            Task { @MainActor in
                self.activeStops = stops
            }
        }
    }

    // MARK: Mark stop complete
    func completeStop(_ stop: Stop) {
        guard let routeId = assignedRoute?.id else { return }

        var updatedStops = activeStops
        if let index = updatedStops.firstIndex(where: { $0.id == stop.id }) {
            updatedStops[index].isCompleted = true
        }

        activeStops = updatedStops
        stopsRepo.saveStops(forRoute: routeId, stops: updatedStops)
    }

    // MARK: Next stop
    var nextStop: Stop? {
        activeStops.first { !$0.isCompleted }
    }
}

