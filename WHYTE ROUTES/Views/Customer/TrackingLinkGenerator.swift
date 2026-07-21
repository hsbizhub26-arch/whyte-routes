import SwiftUI

@MainActor
final class TrackingLinkGeneratorViewModel: ObservableObject {

    @Published var generatedLink: TrackingLink?
    @Published var isLoading = false

    private let routeId: String
    private let stop: Stop
    private let driverId: String

    private let service = RouteService.shared

    init(routeId: String, stop: Stop, driverId: String) {
        self.routeId = routeId
        self.stop = stop
        self.driverId = driverId
    }

    func generate() {
        isLoading = true

        service.createTrackingLink(
            routeId: routeId,
            stop: stop,
            driverId: driverId
        ) { link in
            Task { @MainActor in
                self.generatedLink = link
                self.isLoading = false
            }
        }
    }
}

struct TrackingLinkGenerator: View {

    @StateObject private var vm: TrackingLinkGeneratorViewModel

    init(routeId: String, stop: Stop, driverId: String) {
        _vm = StateObject(wrappedValue: TrackingLinkGeneratorViewModel(
            routeId: routeId, stop: stop, driverId: driverId
        ))
    }

    var body: some View {
        VStack(spacing: 24) {

            Text("Generate Customer Tracking Link")
                .font(.title3.bold())

            if let link = vm.generatedLink {
                VStack(spacing: 12) {
                    Text("Tracking Link Created!")
                        .font(.headline)

                    if let id = link.id {
                        Text("ID: \(id)")
                            .font(.caption)
                            .foregroundColor(.gray)

                        SMSButton(
                            title: "Send to Customer",
                            phone: vm.stop.customerPhone ?? "",
                            link: "https://whyteroutes.app/tracking/\(id)"
                        )
                    }
                }
                .padding()
            }

            if vm.isLoading {
                ProgressView("Generating…")
            } else {
                Button(action: vm.generate) {
                    Text("Generate Link")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.black)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
    }
}
