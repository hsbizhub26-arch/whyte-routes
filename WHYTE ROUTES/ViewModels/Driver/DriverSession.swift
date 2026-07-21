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

    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()

    // MARK: Load driver after login
    func setDriver(_ driver: Driver) {
        self.driver = driver
        loadAssignedRoute()
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

