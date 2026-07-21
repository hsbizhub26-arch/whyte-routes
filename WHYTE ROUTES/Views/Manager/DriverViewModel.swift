import Foundation

@MainActor
final class DriverViewModel: ObservableObject {

    @Published var drivers: [Driver] = []

    private let repo = FirestoreDriversRepository()

    init() {
        load()
    }

    func load() {
        repo.fetchDrivers { drivers in
            DispatchQueue.main.async {
                self.drivers = drivers
            }
        }
    }
}
