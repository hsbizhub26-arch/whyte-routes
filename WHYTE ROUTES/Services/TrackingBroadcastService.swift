import Foundation
import CoreLocation
import MapKit
import Combine

// Publishes route progress to every customer holding a tracking link
// for the route being driven.
//
// PRIVACY IS THE WHOLE DESIGN HERE. Each customer's location document
// is world-readable to whoever holds their (unguessable) link, so
// anything written to it is effectively public. What each customer
// gets therefore depends entirely on whether the truck is currently
// theirs:
//
//   WAITING (someone else is being served):
//     - their queue position, and nothing else. No coordinates.
//   CURRENT (the driver is on the way to them):
//     - live coordinates, heading and a real ETA.
//
// That split is not incidental. An earlier version published
// coordinates to everyone and relied on the queue position being "just
// a number" - which an adversarial review broke: the number CHANGING
// is itself a signal. A customer five stops back watching the count
// drop knows the truck's coordinates at that instant are the home of
// whoever was just finished, and can enumerate every address ahead of
// them that way. Withholding position until a customer is next means
// the only property their map can ever reveal is their own.
//
// The queue position is computed here, in the app, which legitimately
// holds the whole route; only the resulting integer is published, and
// the page never reads the stops collection.
@MainActor
final class TrackingBroadcastService {

    static let shared = TrackingBroadcastService()
    private init() {}

    private let linkRepo = TrackingLinkRepository()
    private var cancellables = Set<AnyCancellable>()
    private var isRunning = false

    /// stopId -> that stop's active tracking link.
    private var linksByStopId: [String: TrackingLink] = [:]
    private var lastPublishedAt: Date?
    private var lastEtaComputedAt: Date?
    private var cachedEtaMinutes: Int?

    // A customer map doesn't need per-second precision, and every
    // publish is a Firestore write multiplied by the number of
    // customers watching. 25s keeps the pin feeling live without
    // turning one route into thousands of writes.
    private static let publishInterval: TimeInterval = 25
    // Directions requests are rate-limited and far more expensive than
    // a write, so the ETA refreshes on its own slower cadence and is
    // reused in between.
    private static let etaRefreshInterval: TimeInterval = 90

    // MARK: - Lifecycle (tied to the shift, like GPS tracking itself)

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshLinks()

        LocationService.shared.$currentLocation
            .compactMap { $0 }
            .sink { [weak self] coordinate in
                Task { @MainActor in self?.handleLocation(coordinate) }
            }
            .store(in: &cancellables)
    }

    func stop() {
        isRunning = false
        cancellables.removeAll()
        linksByStopId.removeAll()
        lastPublishedAt = nil
        lastEtaComputedAt = nil
        cachedEtaMinutes = nil
    }

    /// Re-reads which stops on the current route have live links.
    /// Called on start and whenever a stop completes, since completing
    /// one changes every remaining customer's queue position.
    func refreshLinks() {
        let stops = DriverSession.shared.activeStops
        guard !stops.isEmpty else { return }
        for stop in stops {
            linkRepo.activeLink(forStopId: stop.id) { [weak self] link in
                Task { @MainActor in
                    guard let self, let link else { return }
                    self.linksByStopId[stop.id] = link
                }
            }
        }
    }

    // MARK: - Publishing

    private func handleLocation(_ coordinate: CLLocationCoordinate2D) {
        guard isRunning, !linksByStopId.isEmpty else { return }

        if let last = lastPublishedAt, Date().timeIntervalSince(last) < Self.publishInterval {
            return
        }
        lastPublishedAt = Date()

        guard let companyId = CompanySession.shared.currentCompanyId else { return }

        let ordered = DriverSession.shared.activeStops.sorted { $0.order < $1.order }
        let remaining = ordered.filter { !$0.isCompleted && !$0.isSkipped }
        guard let currentDestination = remaining.first else { return }

        refreshEtaIfStale(to: currentDestination, from: coordinate)

        for (index, stop) in remaining.enumerated() {
            guard let link = linksByStopId[stop.id] else { continue }

            let isCurrent = (index == 0)

            // COORDINATES ONLY FOR THE CUSTOMER BEING DRIVEN TO.
            //
            // An adversarial review caught this: publishing only a
            // COUNT to customers further back is not actually private,
            // because the count CHANGING is itself a signal. Someone
            // five stops down the route watching "4 stops before
            // yours" drop to 3 knows the truck's coordinates at that
            // instant are the home address of whoever was just
            // finished. Repeat for each decrement and they can
            // enumerate every address ahead of them, reverse-geocode
            // it, and timestamp each service.
            //
            // So a waiting customer gets their queue position and
            // nothing else - no coordinates, no heading. The map only
            // starts moving once the truck is genuinely theirs, at
            // which point the only address it can reveal is their own.
            linkRepo.publishLocation(
                companyId: companyId,
                linkId: link.id,
                latitude: isCurrent ? coordinate.latitude : nil,
                longitude: isCurrent ? coordinate.longitude : nil,
                heading: isCurrent ? LocationService.shared.currentHeading : nil,
                stopsBefore: index,
                isCurrentDestination: isCurrent,
                // Only the customer actually being driven to gets an
                // ETA. Publishing one to somebody four stops back
                // would be a guess presented as a fact - how long the
                // driver spends at each property in between is exactly
                // what can't be known.
                etaMinutes: isCurrent ? cachedEtaMinutes : nil
            )
        }
    }

    private func refreshEtaIfStale(to stop: Stop, from coordinate: CLLocationCoordinate2D) {
        if let last = lastEtaComputedAt, Date().timeIntervalSince(last) < Self.etaRefreshInterval {
            return
        }
        guard let destination = stop.coordinate else { return }
        lastEtaComputedAt = Date()

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile

        Task {
            if let eta = try? await MKDirections(request: request).calculateETA() {
                await MainActor.run {
                    self.cachedEtaMinutes = max(0, Int(eta.expectedTravelTime / 60))
                }
            }
        }
    }
}
