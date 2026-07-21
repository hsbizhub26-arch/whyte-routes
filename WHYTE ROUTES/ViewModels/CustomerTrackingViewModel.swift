import Foundation
import CoreLocation

@MainActor
final class CustomerTrackingViewModel: ObservableObject {

    @Published private(set) var driverLocation: CLLocationCoordinate2D?
    @Published private(set) var etaMinutes: Int?
    @Published private(set) var stops: [Stop] = []

    private let trackingRepo = TrackingLinkRepository()
    private let stopsRepo = StopsRepository()
    private let mapbox = MapboxService.shared

    private var driverId: String = ""

    // MARK: - Load Tracking Link
    func loadTracking(linkId: String) {
        trackingRepo.fetchTrackingLink(id: linkId) { link in
            Task { @MainActor in
                guard let link = link else { return }
                self.driverId = link.driverId
                self.listenForDriverUpdates()
                self.loadStops(routeId: link.routeId)
            }
        }
    }

    // MARK: - Listen For Driver Location
    private func listenForDriverUpdates() {
        trackingRepo.listenToDriver(driverId: driverId) { coord in
            Task { @MainActor in
                self.driverLocation = coord
                self.computeETA()
            }
        }
    }

    // MARK: - Load Stops
    private func loadStops(routeId: String) {
        stopsRepo.fetchStops(routeId: routeId) { stops in
            Task { @MainActor in
                self.stops = stops.sorted(by: { $0.order < $1.order })
            }
        }
    }

    // MARK: - ETA Calculation
    private func computeETA() {
        guard let location = driverLocation else { return }
        guard let firstStop = stops.first else { return }

        let stopCoord = CLLocationCoordinate2D(latitude: firstStop.latitude ?? 0,
                                               longitude: firstStop.longitude ?? 0)

        mapbox.estimateETA(from: location, to: stopCoord) { minutes in
            Task { @MainActor in
                self.etaMinutes = minutes
            }
        }
    }
}
