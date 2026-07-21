import SwiftUI
import MapKit

@MainActor
final class ActivityViewModel: ObservableObject {

    @Published var stop: Stop?
    @Published var driver: Driver?
    @Published var driverLocation: CLLocationCoordinate2D?
    @Published var isLoading = true

    private let routeId: String
    private let stopId: String

    private let stopsRepo = StopsRepository()
    private let driverRepo = FirestoreDriverRepository()

    init(routeId: String, stopId: String) {
        self.routeId = routeId
        self.stopId = stopId
        load()
        listenForDriverUpdates()
    }

    func load() {
        isLoading = true
        stopsRepo.loadStops(forRoute: routeId) { stops in
            Task { @MainActor in
                self.stop = stops.first { $0.id == stopId }
                self.isLoading = false
            }
        }
    }

    func listenForDriverUpdates() {
        driverRepo.listenToDrivers { drivers in
            Task { @MainActor in
                guard let stop = self.stop else { return }
                self.driver = drivers.first { $0.id == stop.driverId }
                self.driverLocation = self.driver?.coordinate
            }
        }
    }
}

struct ActivityView: View {

    @StateObject var vm: ActivityViewModel

    init(routeId: String, stopId: String) {
        _vm = StateObject(wrappedValue: ActivityViewModel(routeId: routeId, stopId: stopId))
    }

    var body: some View {
        VStack(spacing: 20) {

            if vm.isLoading {
                ProgressView("Loading…")
                    .padding(.top, 40)
            }

            if let stop = vm.stop {
                VStack(alignment: .leading, spacing: 8) {
                    Text(stop.address)
                        .font(.title3).bold()

                    Text("Status: \(stop.isCompleted ? "Completed" : "In Progress")")
                        .foregroundColor(stop.isCompleted ? .green : .yellow)

                    if let driver = vm.driver {
                        Text("Driver: \(driver.name)")
                            .foregroundColor(.secondary)

                        if let loc = vm.driverLocation {
                            Text("Driver Location: \(loc.latitude, specifier: "%.4f"), \(loc.longitude, specifier: "%.4f")")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            if let location = vm.driverLocation {
                Map(coordinateRegion: .constant(
                    MKCoordinateRegion(
                        center: location,
                        span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                ))
                .frame(height: 300)
                .cornerRadius(12)
                .padding(.horizontal)
            } else {
                Text("Waiting for driver location…")
                    .foregroundColor(.gray)
            }

            Spacer()
        }
        .navigationTitle("Activity")
    }
}
