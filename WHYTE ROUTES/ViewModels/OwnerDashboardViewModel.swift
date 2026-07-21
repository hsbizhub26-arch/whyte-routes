import Foundation

@MainActor
final class OwnerDashboardViewModel: ObservableObject {

    @Published private(set) var totalDrivers: Int = 0
    @Published private(set) var totalRoutes: Int = 0
    @Published private(set) var completedStops: Int = 0

    private let driverRepo = FirestoreDriverRepository()
    private let routeService = RouteService.shared
    private let stopsRepo = StopsRepository()

    init() {
        refreshDashboard()
    }

    func refreshDashboard() {
        loadDrivers()
        loadRoutes()
    }

    private func loadDrivers() {
        driverRepo.fetchDrivers { drivers in
            Task { @MainActor in
                self.totalDrivers = drivers.count
            }
        }
    }

    private func loadRoutes() {
        routeService.loadRoutes()

        Task { @MainActor in
            try await Task.sleep(nanoseconds: 200_000_000)

            let routes = routeService.routes
            self.totalRoutes = routes.count

            self.loadCompletedStops(for: routes)
        }
    }

    private func loadCompletedStops(for routes: [Route]) {
        var count = 0

        let group = DispatchGroup()

        for route in routes {
            group.enter()
            stopsRepo.fetchStops(routeId: route.id ?? "") { stops in
                count += stops.filter { $0.isCompleted }.count
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.completedStops = count
        }
    }
}
