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
    /// Where the truck was when it last genuinely moved, and when.
    /// Drives the break detection below - see breakGracePeriod.
    private var lastMovementCoordinate: CLLocationCoordinate2D?
    private var lastMovedAt: Date?
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
    // A driver stopping for fuel, a washroom or a coffee is normal and
    // none of the customer's business - but a live pin parked outside a
    // gas station reads as slacking, and it is the DRIVER who wears
    // that. Past this much time without meaningful movement mid-drive,
    // the position is withheld.
    private static let breakGracePeriod: TimeInterval = 4 * 60
    // Far enough that GPS jitter at a standstill never counts as
    // movement, short enough that genuinely pulling away does.
    private static let movementThreshold: CLLocationDistance = 40

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
            // Matched on the CUSTOMER the stop points at now, not on
            // the stop id. Staff can re-point a stop at somebody else
            // mid-route without its id changing, and a stopId-only
            // lookup would keep handing back the previous customer's
            // link for the rest of the shift - publishing the truck's
            // position, and eventually its arrival, into a page still
            // showing that customer their own name and address.
            linkRepo.activeLink(for: stop) { [weak self] link in
                Task { @MainActor in
                    guard let self else { return }
                    guard let link else {
                        // Drop any link previously cached for this
                        // stop. Without this, a link that stops
                        // matching - because the stop was re-pointed,
                        // or the link was superseded - would keep
                        // being published to from the in-memory cache
                        // for as long as the shift lasted.
                        self.linksByStopId.removeValue(forKey: stop.id)
                        return
                    }
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

        // ── Break detection ───────────────────────────────────────
        // Gas, washroom, coffee, waiting on a locked gate: all normal,
        // none of it the customer's business. A stationary pin outside
        // a Tim Hortons invites "thought you were on the way?", and the
        // driver is the one who has to answer for it. So once the truck
        // has not meaningfully moved for breakGracePeriod, coordinates
        // are withheld and the customer sees exactly what they saw
        // before the truck set off: "On the way to you", with an ETA.
        // No pin frozen in a parking lot. Movement restores it on its
        // own - there is nothing for a driver to remember to switch
        // back on, which matters at 5am in the cold.
        if let anchor = lastMovementCoordinate {
            let moved = here.distance(from: CLLocation(latitude: anchor.latitude,
                                                       longitude: anchor.longitude))
            if moved >= Self.movementThreshold {
                lastMovementCoordinate = coordinate
                lastMovedAt = Date()
            }
        } else {
            lastMovementCoordinate = coordinate
            lastMovedAt = Date()
        }
        let isOnABreak = Date().timeIntervalSince(lastMovedAt ?? Date()) >= Self.breakGracePeriod

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

            // Re-checked here even though refreshLinks already filters
            // on it, because this cache is filled asynchronously: the
            // stops listener can deliver a re-pointed stop and publish
            // against the entry still sitting in memory before the
            // replacement query comes back. One comparison of two
            // strings against the risk of streaming a truck's approach
            // and arrival into the wrong customer's page.
            guard link.belongsTo(stop) else {
                linksByStopId.removeValue(forKey: stop.id)
                continue
            }

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

            // Once the driver has arrived, keep the pin alive - but
            // only while the truck is genuinely at THIS customer's
            // address, where the only thing its position can reveal is
            // that customer's own house.
            //
            // The proximity test is what makes this safe. A driver who
            // arrives and then leaves without completing would
            // otherwise keep this stop at the head of the queue and
            // stream their position onward to the next property, which
            // is the abandoned-stop leak in a different disguise.
            let arrivedAndStillHere: Bool = {
                guard status == .arrived,
                      let mine = stop.coordinate else { return false }
                return here.distance(from: CLLocation(latitude: mine.latitude, longitude: mine.longitude))
                    <= Self.completedStopShadowRadius
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
                && (enRouteRecently || arrivedAndStillHere)
                && fixIsTrustworthy
                && !sittingOnAFinishedProperty
                // Parked mid-drive: withhold. Deliberately NOT applied
                // to arrivedAndStillHere - a driver who has arrived is
                // MEANT to be stationary, and that customer should keep
                // seeing the truck at their own address.
                && !(isOnABreak && !arrivedAndStillHere)

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
                // The PROXIMITY-CHECKED arrival, not the raw status.
                //
                // "Your driver is here" on the strength of the status
                // alone outlives the thing it describes: a driver who
                // taps Arrived and then leaves without completing -
                // wrong house, nobody home, called away - leaves that
                // customer's page insisting the truck is in their
                // driveway for the rest of the shift. The pin already
                // went quiet the moment the truck left the property;
                // this makes the sentence above it go quiet too,
                // instead of contradicting it.
                hasArrived: arrivedAndStillHere,
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
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)))
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
