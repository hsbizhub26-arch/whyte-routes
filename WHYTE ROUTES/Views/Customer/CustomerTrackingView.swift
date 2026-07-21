import SwiftUI
import MapKit

@MainActor
final class CustomerTrackingViewModel: ObservableObject {

    @Published var link: TrackingLink?
    @Published var driver: Driver?
    @Published var driverLocation: CLLocationCoordinate2D?
    @Published var isLoading = true

    private let linkId: String
    private let repo = TrackingLinkRepository()
    private let driverRepo = FirestoreDriverRepository()

    init(linkId: String) {
        self.linkId = linkId
        listenToLink()
        listenToDriver()
    }

    private func listenToLink() {
        repo.listenTo(linkId: linkId) { link in
            Task { @MainActor in
                self.link = link
                self.isLoading = false
            }
        }
    }

    private func listenToDriver() {
        driverRepo.listenToDrivers { drivers in
            Task { @MainActor in
                guard let driverId = self.link?.driverId else { return }
                self.driver = drivers.first { $0.id == driverId }
                self.driverLocation = self.driver?.coordinate
            }
        }
    }
}

struct CustomerTrackingView: View {

    @StateObject private var vm: CustomerTrackingViewModel

    init(linkId: String) {
        _vm = StateObject(wrappedValue: CustomerTrackingViewModel(linkId: linkId))
    }

    var body: some View {
        VStack(spacing: 16) {

            if vm.isLoading {
                ProgressView("Loading tracking…")
                Spacer()
            }

            if let link = vm.link {
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.customerName)
                        .font(.title3.bold())

                    Text(link.address)
                        .foregroundColor(.secondary)
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
                .frame(height: 350)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            } else {
                Text("Waiting for driver location…")
                    .foregroundColor(.gray)
            }

            Spacer()
        }
        .navigationTitle("Live Tracking")
    }
}
