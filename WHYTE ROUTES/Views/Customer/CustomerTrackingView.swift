import SwiftUI
import MapKit

@MainActor
final class CustomerTrackingViewModel: ObservableObject {

    @Published var link: TrackingLink?
    @Published var driver: Driver?
    @Published var driverLocation: CLLocationCoordinate2D?
    @Published var isLoading = true

    private let companyId: String
    private let linkId: String
    private let repo = TrackingLinkRepository()
    private let driverRepo = FirestoreDriverRepository()

    init(companyId: String, linkId: String) {
        self.companyId = companyId
        self.linkId = linkId
        listenToLink()
    }

    private func listenToLink() {
        repo.listenTo(companyId: companyId, linkId: linkId) { link in
            Task { @MainActor in
                self.link = link
                self.isLoading = false
                if let driverId = link?.driverId {
                    self.listenToDriver(driverId: driverId)
                }
            }
        }
    }

    // NOTE: companies/{companyId}/drivers/{id} contains PII (name, phone)
    // and is intentionally locked to authenticated users in the security
    // rules - an unauthenticated customer will get no data here, which is
    // correct/safe, not a bug. Before this screen is wired into the app,
    // switch this to read a public-safe position-only document instead
    // (e.g. trackingLinks/{linkId}/location) rather than loosening the
    // drivers collection's rules.
    private func listenToDriver(driverId: String) {
        driverRepo.listenToDriver(companyId: companyId, driverId: driverId) { driver in
            Task { @MainActor in
                self.driver = driver
                self.driverLocation = driver?.coordinate
            }
        }
    }
}

struct CustomerTrackingView: View {

    @StateObject private var vm: CustomerTrackingViewModel

    init(companyId: String, linkId: String) {
        _vm = StateObject(wrappedValue: CustomerTrackingViewModel(companyId: companyId, linkId: linkId))
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
