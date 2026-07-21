import Foundation

@MainActor
final class ManagerViewModel: ObservableObject {

    @Published private(set) var routes: [Route] = []
    @Published private(set) var drivers: [Driver] = []
    @Published var isLoading = false

    private let routeService = RouteService.shared
    private let driversRepo: DriversRepository = FirestoreDriversRepository()

    init() {
        reloadAll()
    }

    func reloadAll() {
        isLoading = true

        // Load routes
        routeService.loadRoutes()

        // Load drivers
        driversRepo.fetchDrivers { drivers in
            Task { @MainActor in
                self.drivers = drivers
                self.routes = self.routeService.routes
                self.isLoading = false
            }
        }
    }

    func assign(driver: Driver, to route: Route) {
        guard let routeId = route.id else { return }

        // Update Firestore
        Firestore.firestore()
            .collection("routes")
            .document(routeId)
            .updateData(["driverId": driver.id ?? ""])

        reloadAll()
    }
}
