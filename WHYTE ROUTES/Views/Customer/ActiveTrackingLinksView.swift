import SwiftUI
import FirebaseFirestore

@MainActor
final class ActiveTrackingLinksViewModel: ObservableObject {
    @Published var links: [TrackingLink] = []
    @Published var isLoading = true

    private let repo = TrackingLinkRepository()

    init() {
        loadActiveLinks()
    }

    func loadActiveLinks() {
        isLoading = true

        Firestore.firestore()
            .collection("trackingLinks")
            .whereField("active", isEqualTo: true)
            .addSnapshotListener { snapshot, error in

                Task { @MainActor in
                    guard
                        error == nil,
                        let docs = snapshot?.documents
                    else {
                        self.links = []
                        self.isLoading = false
                        return
                    }

                    self.links = docs.compactMap {
                        try? $0.data(as: TrackingLink.self)
                    }

                    self.isLoading = false
                }
            }
    }

    func deactivate(_ link: TrackingLink) {
        guard let id = link.id else { return }
        // Uses the stored repo rather than a temporary, for the same
        // reason as DriverStopViewModel.trackingRepo.
        repo.deactivate(id: id)
    }
}

struct ActiveTrackingLinksView: View {

    @StateObject private var vm = ActiveTrackingLinksViewModel()

    var body: some View {
        List {
            ForEach(vm.links) { link in
                VStack(alignment: .leading, spacing: 6) {
                    Text(link.customerName)
                        .font(.headline)

                    Text(link.address)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("Driver: \(link.driverId)")
                        .font(.caption)
                        .foregroundColor(.gray)

                    HStack {
                        Button("Open Link") {
                            if let id = link.id {
                                let url = URL(string: "https://whyteroutes.app/tracking/\(id)")
                                if let url { UIApplication.shared.open(url) }
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Deactivate") {
                            vm.deactivate(link)
                        }
                        .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Active Tracking Links")
        .overlay {
            if vm.isLoading {
                ProgressView("Loading…")
            }
        }
    }
}
