import Foundation
import Combine
import SwiftUI

@MainActor
final class StopsViewModel: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var stops: [AppStop] = []

    private let routeService = RouteService.shared

    init() {}

    func load(for route: AppRoute?) {
        guard let route else {
            self.stops = []
            return
        }
        isLoading = true
        routeService.loadStops(for: route) { [weak self] stops in
            Task { @MainActor in
                self?.stops = stops
                self?.isLoading = false
            }
        }
    }

    func save(for route: AppRoute?) {
        guard let route else { return }
        routeService.saveStops(stops, for: route)
    }
}
