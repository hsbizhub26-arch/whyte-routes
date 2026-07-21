import Foundation
import Combine

@MainActor
final class RoutesViewModel: ObservableObject {

    @Published var routes: [Route] = []

    private let repo = RouteRepository()

    init() {
        load()
    }

    func load() {
        repo.fetchRoutes { routes in
            DispatchQueue.main.async {
                self.routes = routes
            }
        }
    }
}
