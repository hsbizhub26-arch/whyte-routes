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
// That split is not incidental, and it took two rounds of adversarial
// review to get right. Both are recorded here because each fix looked
// obviously sufficient until it wasn't:
//
//  1. Coordinates once went to everyone, defended on the grounds that
//     the queue position was "just a number". The number CHANGING is
//     itself a signal: a customer five stops back watching the count
//     drop knows the truck's coordinates at that instant are the home
//     of whoever was just finished, and can enumerate every address
//     ahead of them that way.
//  2. Withholding coordinates until a customer is next was then
//     claimed to mean "the only property their map can reveal is their
//     own". Also false - the driver taps Completed standing in the
//     PREVIOUS customer's driveway, so the first fix the newly-next
//     customer receives pins that neighbour's house, timestamped.
//
// Hence the three gates below, none of which is redundant: coordinates
// require the customer to be next, the driver to have actually started
// driving to them recently, and the truck not to be sitting on a
// property that has already been serviced.
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
    // Set when the queue changes (a stop completed, links reloaded).
    // Without it the newly-next customer waits out the 25s throttle -
    // and, because location updates only fire after 20m of movement,
    // a driver who finishes a stop and stands at the truck could leave
    // that customer on a pin-less map for far longer than that. The
    // moment someone becomes next, they should see the truck.
    private var forceNextPublish = false
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
    // No position is published while within this distance of an
    // already-completed stop - that is someone else's driveway.
    private static let completedStopShadowRadius: CLLocationDistance = 75
    // Matches the geofence's own threshold. Neighbouring houses are
    // ~20m apart, so a vaguer fix can rank the wrong property nearest.
    private static let maxUsableAccuracy: CLLocationAccuracy = 25
    // A local drive between stops does not take this long. Past it,
    // the stop is presumed abandoned rather than genuinely en route,
    // and its customer stops receiving a position.
    private static let maxEnRouteDuration: TimeInterval = 90 * 60

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
        forceNextPublish = true
        for stop in stops {
            linkRepo.activeLink(forStopId: stop.id) { [weak self] link in
                Task { @MainActor in
                    guard let self, let link else { return }
                    self.linksByStopId[stop.id] = link
                    self.publishImmediatelyIfQueueChanged()
                }
            }
        }
    }

    /// Pushes one publish straight away after a queue change, rather
    /// than waiting for the throttle and the next GPS fix.
    private func publishImmediatelyIfQueueChanged() {
        guard forceNextPublish,
              let coordinate = LocationService.shared.currentLocation else { return }
        forceNextPublish = false
        lastPublishedAt = nil
        // Status and queue position only. This fires at the instant a
        // stop is completed, when the cached fix is the truck standing
        // at that just-finished property - exactly the coordinate that
        // must not be handed to the next customer. Their map comes
        // alive on the next real movement instead.
        handleLocation(coordinate, allowCoordinates: false)
    }

    // MARK: - Publishing

    private func handleLocation(_ coordinate: CLLocationCoordinate2D, allowCoordinates: Bool = true) {
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

        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // Distance to the nearest ALREADY-SERVICED property. Position
        // is withheld while the truck is sitting on one of those - the
        // driver taps Completed standing in that customer's driveway,
        // and the first fix the newly-next customer is allowed to see
        // would otherwise pin their neighbour's house, stamped with
        // the moment that neighbour's service ended.
        let nearestCompleted = ordered
            .filter { $0.isCompleted }
            .compactMap { $0.coordinate }
            .map { here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
            .min()

        // A fix too vague to trust must not be published at all. A
        // reading accurate only to 150m can place the truck outside an
        // exclusion zone it is physically parked inside, which would
        // defeat the check above precisely when it matters.
        let accuracy = LocationService.shared.currentAccuracy
        let fixIsTrustworthy = (accuracy ?? .greatestFiniteMagnitude) <= Self.maxUsableAccuracy

        for (index, stop) in remaining.enumerated() {
            guard let link = linksByStopId[stop.id] else { continue }

            // Being at the head of the queue is not enough to earn a
            // live position. The driver must have actually STARTED
            // DRIVING to this customer, and recently.
            //
            // Otherwise a stop the driver silently skips - serviced
            // but never marked complete, or abandoned at end of shift -
            // pins the queue head permanently, and that one customer
            // then watches the truck visit every other property on the
            // route for the rest of the day. A stale enRouteAt is the
            // tell, so it is bounded rather than trusted.
            let status = JobStatus(rawValue: stop.status) ?? .scheduled
            let enRouteRecently: Bool = {
                guard status == .enRoute, let since = stop.enRouteAt else { return false }
                return Date().timeIntervalSince(since) <= Self.maxEnRouteDuration
            }()

            let isCurrent = (index == 0)

            // NEAREST WINS, rather than a flat exclusion radius.
            //
            // An absolute "within 75m of any completed stop" test
            // breaks on exactly the routes this app is for: houses sit
            // ~20m apart, so once one is done every remaining stop on
            // the street is inside that radius and the map would go
            // dead for the rest of the route. Comparing distances
            // instead means the truck stops being "at" the finished
            // property the moment it is closer to this customer's own
            // address - which is also the only address its position
            // can then reveal.
            let distanceToThisCustomer = stop.coordinate.map {
                here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            }
            let sittingOnAFinishedProperty: Bool = {
                guard let nearestCompleted else { return false }
                guard nearestCompleted <= Self.completedStopShadowRadius else { return false }
                // Inside the shadow, but if this customer's own house
                // is nearer then the truck is arriving here, not
                // loitering there.
                guard let distanceToThisCustomer else { return true }
                return nearestCompleted <= distanceToThisCustomer
            }()

            let mayShareCoordinates = isCurrent
                && allowCoordinates
                && enRouteRecently
                && fixIsTrustworthy
                && !sittingOnAFinishedProperty

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
                latitude: mayShareCoordinates ? coordinate.latitude : nil,
                longitude: mayShareCoordinates ? coordinate.longitude : nil,
                heading: mayShareCoordinates ? LocationService.shared.currentHeading : nil,
                stopsBefore: index,
                isCurrentDestination: isCurrent,
                // Only the customer actually being driven to gets an
                // ETA. Publishing one to somebody four stops back
                // would be a guess presented as a fact - how long the
                // driver spends at each property in between is exactly
                // what can't be known.
                etaMinutes: mayShareCoordinates ? cachedEtaMinutes : nil
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
