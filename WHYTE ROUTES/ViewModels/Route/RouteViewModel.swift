import Foundation

@MainActor
final class RouteViewModel: ObservableObject {

    @Published private(set) var routes: [Route] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let service = RouteService.shared

    init() {
        loadRoutes()
    }

    // MARK: - Load All Routes
    func loadRoutes() {
        isLoading = true
        errorMessage = nil

        service.loadRoutes()

        // RouteService updates its own storage; we mirror it here
        Task { @MainActor in
            try await Task.sleep(nanoseconds: 150_000_000)
            self.routes = service.routes
            self.isLoading = false
        }
    }

    // MARK: - Assign Driver
    func assignDriver(route: Route, driverId: String) {
        service.assignDriver(route: route, driverId: driverId)
        loadRoutes()
    }

    // MARK: - Update Route Status (Active, Completed, etc.)
    func updateStatus(route: Route, status: String) {
        service.updateStatus(route: route, status: status)
        loadRoutes()
    }
}
