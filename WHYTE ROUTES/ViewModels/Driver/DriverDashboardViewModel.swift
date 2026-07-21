import Foundation

@MainActor
final class DriverDashboardViewModel: ObservableObject {

    @Published var nextStop: Stop?
    @Published var completed: Int = 0
    @Published var total: Int = 0

    private let session = DriverSession.shared

    init() {
        refresh()
    }

    func refresh() {
        total = session.activeStops.count
        completed = session.activeStops.filter { $0.completed }.count
        nextStop = session.activeStops.first { !$0.completed }
    }
}
