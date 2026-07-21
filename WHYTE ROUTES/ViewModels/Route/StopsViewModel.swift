import Foundation

@MainActor
final class StopsViewModel: ObservableObject {

    @Published private(set) var stops: [Stop] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let service = RouteService.shared
    private let route: Route

    // MARK: - Init
    init(route: Route) {
        self.route = route
        loadStops()
    }

    // MARK: - Load Stops for Route
    func loadStops() {
        guard let routeId = route.id else { return }

        isLoading = true
        errorMessage = nil

        service.loadStops(for: route) { stops in
            Task { @MainActor in
                self.stops = stops.sorted(by: { $0.order < $1.order })
                self.isLoading = false
            }
        }
    }

    // MARK: - Toggle Completion
    func toggleStopCompletion(_ stop: Stop) {
        guard let index = stops.firstIndex(where: { $0.id == stop.id }) else { return }

        stops[index].isCompleted.toggle()
        service.saveStops(stops, for: route)
    }

    // MARK: - Reorder Stops
    func reorderStops(from source: IndexSet, to destination: Int) {
        stops.move(fromOffsets: source, toOffset: destination)

        // Update ordering
        for i in 0..<stops.count {
            stops[i].order = i
        }

        service.saveStops(stops, for: route)
    }

    // MARK: - Refresh (for pull to refresh UI)
    func refresh() {
        loadStops()
    }
}
