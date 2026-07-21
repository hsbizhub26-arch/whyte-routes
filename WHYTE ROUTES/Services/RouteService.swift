import Foundation

@MainActor
final class RouteService: ObservableObject {

    static let shared = RouteService()
    private init() {}

    @Published var routes: [Route] = []

    private let routeRepo: RoutesRepository = FirestoreRouteRepository()
    private let stopsRepo: StopsRepository = FirestoreStopsRepository()

    // MARK: - Load all routes
    func loadRoutes() {
        routeRepo.fetchRoutes { routes in
            Task { @MainActor in
                self.routes = routes
            }
        }
    }

    // MARK: - Load stops for a route
    func loadStops(for route: Route, completion: @escaping ([Stop]) -> Void) {
        guard let id = route.id else {
            completion([])
            return
        }

        stopsRepo.loadStops(forRoute: id, completion: completion)
    }

    // MARK: - Save stops after reordering or marking as completed
    func saveStops(_ stops: [Stop], for route: Route) {
        guard let id = route.id else { return }
        stopsRepo.saveStops(forRoute: id, stops: stops)
    }
}
