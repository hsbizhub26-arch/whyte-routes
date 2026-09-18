import SwiftUI
import MapKit
import Combine

@MainActor
final class DriverMapViewModel: ObservableObject {

    // Follows the driver natively via MapKit rather than us writing a
    // new region on every fix - see startLocationUpdates for why that
    // mattered. The region is only a fallback for before the first fix
    // arrives.
    @Published var cameraPosition: MapCameraPosition = .userLocation(
        fallback: .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
                span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04)
            )
        )
    )

    @Published var driverCoordinate: CLLocationCoordinate2D?
    @Published var stops: [Stop] = []
    @Published var selectedStop: Stop?

    private let session = DriverSession.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        observeStops()
        startLocationUpdates()
    }

    /// Keeps the pins LIVE.
    ///
    /// This used to be a one-shot `loadStops()` called from init, so
    /// `stops` froze at whatever activeStops happened to hold the
    /// instant the map first appeared. A route that finished loading a
    /// moment later never drew any pins at all, and a stop completed
    /// mid-shift never turned green - the map just quietly stopped
    /// being true. Sorting once here rather than in `body` also keeps
    /// the numbering stable without re-sorting on every render pass.
    private func observeStops() {
        session.$activeStops
            .map { $0.sorted { $0.order < $1.order } }
            .receive(on: DispatchQueue.main)
            // assign(to: &$stops), NOT assign(to:\.stops, on: self). The
            // latter captures self strongly and, stored in cancellables,
            // forms a retain cycle that leaks this view model for the life
            // of the app. The &$ form is lifetime-managed by the
            // @Published property and holds no strong reference back.
            .assign(to: &$stops)
    }

    // Observes whatever LocationService is already publishing - actual
    // tracking start/stop is tied to the shift lifecycle (see
    // DriverSession.startShift/endShift), not to this screen appearing.
    //
    // NOTE what this deliberately no longer does: write cameraPosition.
    // It used to slam the camera back to a fresh region centred on the
    // driver on every single fix - and with distanceFilter at 20m that
    // is every 20 metres of driving. The driver could not pan or zoom
    // the map at all; it snapped back under their finger, which is a
    // large part of why the screen felt broken. MapKit follows the user
    // on its own via .userLocation above, and stops following the
    // moment they pan, which is the behaviour anyone expects.
    func startLocationUpdates() {
        LocationService.shared.$currentLocation
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coordinate in
                self?.driverCoordinate = coordinate
            }
            .store(in: &cancellables)
    }

    func centerOnDriver() {
        cameraPosition = .userLocation(fallback: .automatic)
    }

    /// The region the map is actually showing, kept current by
    /// onMapCameraChange. Needed because cameraPosition is usually
    /// .userLocation(...) rather than a region, so there is nothing to
    /// read a span off when the driver asks to zoom - MapKit knows
    /// where the camera is, this is how we find out.
    var visibleRegion: MKCoordinateRegion?

    /// Zoom by a factor around whatever is on screen right now.
    /// Switching to an explicit .region also stops the camera following
    /// the driver, which is the right behaviour: someone who just
    /// pinched out to see the rest of their route does not want the map
    /// snapping back to their own dot on the next GPS fix. The locate
    /// button puts them back.
    func zoom(by factor: Double) {
        guard let region = visibleRegion else { return }
        // Clamped so repeated taps can't invert the span or zoom out
        // past the whole world, both of which MapKit renders as a
        // blank grey rectangle.
        let latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.0008), 120)
        let longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.0008), 120)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: region.center,
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            )
        )
    }
}

// MARK: - Route overview geometry

/// Road-following lines for the My Route overview - replacing the single
/// straight "connect the dots" line, which cut across highways, golf
/// courses and houses and read as a mess next to Waze's route preview.
///
/// What shapes this is cost. Directions come from Apple (MKDirections, the
/// same service navigation uses, and the same per-app throttle), so a leg
/// is only asked for when it's genuinely needed:
/// - Stop-to-stop legs are fetched once and cached for the session, keyed
///   by coordinates AND the toll/highway preferences.
/// - The truck's own leg is trimmed to start at the truck as it drives, so
///   driving along it costs nothing. It's re-asked for only when the truck
///   has left it AND moved 200m since the last ask - and each re-ask for the
///   same stop doubles the wait before the next (20s up to 5 min). The wait
///   resets only when the next stop changes or the truck has genuinely
///   followed its line for 300m. Not merely for matching a line: a fresh
///   line always starts at the truck, so matching it proves nothing.
/// - Nothing is asked for while the map is off screen or the app is in the
///   background.
/// - Requests go one at a time, truck's leg first, paced. Failures retry
///   with a growing delay, and a wake-up retries them even when the truck is
///   parked and nothing else would trigger it.
final class RouteOverviewPlanner: ObservableObject {

    enum Style { case current, currentApproximate, upcoming, approximate }

    struct Leg: Identifiable {
        let id: String
        let style: Style
        let coordinates: [CLLocationCoordinate2D]
    }

    /// Stop-to-stop legs. Only reassigned when they actually change - a GPS
    /// fix alone never touches them - so the map isn't handed a fresh set
    /// of overlays every second on a long route.
    @Published private(set) var stopLegs: [Leg] = []
    /// The truck's own leg, published on its own because it changes on
    /// every fix (it's trimmed to start at the truck).
    @Published private(set) var truckLeg: Leg?

    private static let maxRoutedLegs = 12
    /// How far the truck can be from its line before the line is treated as
    /// stale. Measured to the nearest SEGMENT, not vertex - a long straight
    /// road has vertices hundreds of metres apart.
    private static let offRouteTolerance: CLLocationDistance = 120
    /// Arrived: this close to the stop along the road (or in a straight
    /// line, before there is a road). No leg is drawn and nothing is asked.
    private static let arrivalRadius: CLLocationDistance = 100
    private static let rerequestMinMove: CLLocationDistance = 200
    /// Following the line this far is what earns the back-off its reset.
    private static let followedDistance: CLLocationDistance = 300
    /// How far ahead of its last position along the line the truck may be
    /// matched in one step. Beyond it only when nothing nearer fits - so a
    /// road that doubles back past itself can't capture the line.
    private static let matchLookahead: CLLocationDistance = 500
    private static let truckBackoffStart: TimeInterval = 20
    private static let truckBackoffMax: TimeInterval = 300
    private static let throttleBackoff: TimeInterval = 60
    private static let retryStart: TimeInterval = 30
    private static let retryMax: TimeInterval = 600
    /// Apple says there's no road for this leg. Not treated as permanent -
    /// it's also what MapKit reports for some passing outages - but not
    /// worth asking again for a long while either.
    private static let noRouteRetry: TimeInterval = 1800

    /// Shared across map instances, so re-opening the tab requests nothing.
    private static var legCache: [String: [CLLocationCoordinate2D]] = [:]

    private struct Job {
        let key: String
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
        let settings: NavigationSettings
        /// Set for the truck's leg: the target key of the stop it leads to.
        let truckTarget: String?
    }

    private struct TruckRoad {
        let target: String
        let coordinates: [CLLocationCoordinate2D]
        /// Distance along the road to the start of each point, in metres.
        let along: [CLLocationDistance]
        /// Last segment the truck was matched to.
        var progress = 0
        var followed = false

        init(target: String, coordinates: [CLLocationCoordinate2D]) {
            self.target = target
            self.coordinates = coordinates
            var along: [CLLocationDistance] = [0]
            for index in 1..<coordinates.count {
                along.append(along[index - 1] + RouteOverviewPlanner.distance(coordinates[index - 1], coordinates[index]))
            }
            self.along = along
        }
    }

    private var truckRoad: TruckRoad?
    private var truckRequestTarget: String?
    private var truckRequestOrigin: CLLocationCoordinate2D?
    private var truckRequestedAt = Date.distantPast
    private var truckBackoff = RouteOverviewPlanner.truckBackoffStart

    private var queue: [Job] = []
    private var queuedKeys: Set<String> = []
    private var retryAt: [String: Date] = [:]
    private var retryDelay: [String: TimeInterval] = [:]
    private var throttledUntil = Date.distantPast
    private var worker: Task<Void, Never>?
    private var wakeup: Task<Void, Never>?
    private var wakeupAt = Date.distantFuture

    /// What the latest rebuild still wants. Queued jobs outside it are
    /// dropped, and a truck-leg result for any other stop is ignored - so a
    /// stop completed while its request was in flight can't overwrite the
    /// line to the next one.
    private var wantedKeys: Set<String> = []
    private var wantedTruckTarget: String?

    private var stops: [Stop] = []
    private var driver: CLLocationCoordinate2D?
    /// Passed in, never read from CompanySession: @Published delivers the
    /// new value BEFORE the property changes, so reading it back inside the
    /// change handler would see the old one.
    private var settings: NavigationSettings?
    private var isActive = true
    private var stopLegSignature: [String] = []

    func update(stops: [Stop], driver: CLLocationCoordinate2D?) {
        self.stops = stops
        self.driver = driver
        rebuild()
    }

    /// The company's toll/highway settings arrived or changed. They're part
    /// of every cache key, so the next rebuild draws correctly-routed legs.
    func update(settings: NavigationSettings) {
        self.settings = settings
        rebuild()
    }

    /// Paused while the map is off screen or the app is in the background.
    /// Inputs are still recorded, nothing is drawn or asked for, and a queued
    /// truck request is dropped: its starting point would be stale by the
    /// time it went out.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard active else {
            for job in queue where job.truckTarget != nil { queuedKeys.remove(job.key) }
            queue.removeAll { $0.truckTarget != nil }
            return
        }
        rebuild()
        startWorker()
    }

    private func rebuild() {
        guard isActive else { return }

        let pending = stops.filter { !$0.isCompleted && !$0.isSkipped }
        var prefs: String?
        if let settings { prefs = Self.prefsKey(settings) }
        var jobs: [Job] = []

        // Stop to stop, over pending stops that have a location.
        let located = pending.compactMap { $0.coordinate }
        var legs: [Leg] = []
        for (index, pair) in zip(located, located.dropFirst()).enumerated() {
            let (from, to) = pair
            // Two stops at one address (front and back of a lot).
            guard Self.distance(from, to) > 5 else { continue }
            let cacheKey = (prefs ?? "") + "|" + Self.key(from) + ">" + Self.key(to)
            // The preferences are in the id, so switching them back to a set
            // already cached still republishes the right roads.
            let id = "leg-\(index)-\(cacheKey)"
            if prefs != nil, let road = Self.legCache[cacheKey] {
                legs.append(Leg(id: id, style: .upcoming, coordinates: road))
                continue
            }
            legs.append(Leg(id: id, style: .approximate, coordinates: [from, to]))
            if let settings, index < Self.maxRoutedLegs {
                jobs.append(Job(key: cacheKey, from: from, to: to, settings: settings, truckTarget: nil))
            }
        }
        let signature = legs.map { "\($0.id):\($0.style)" }
        if signature != stopLegSignature {
            stopLegSignature = signature
            stopLegs = legs
        }

        // The truck's leg: to the first pending stop in route order - the
        // same stop the dashboard card names. If that stop has no location
        // there's no truck leg, rather than a bold line to a later pin.
        wantedTruckTarget = nil
        var leg: Leg?
        if let driver, let next = pending.first?.coordinate {
            let target = (prefs ?? "") + "|" + Self.key(next)
            if var road = truckRoad, road.target == target,
               let match = Self.remainder(of: road, from: driver) {
                // Arrived is judged along the road: a stop across a divided
                // highway can be 90m away in a straight line and 2km to drive.
                if match.remaining > Self.arrivalRadius {
                    wantedTruckTarget = target
                    road.progress = match.segment
                    if !road.followed, match.along >= Self.followedDistance {
                        road.followed = true
                        truckBackoff = Self.truckBackoffStart
                    }
                    truckRoad = road
                    leg = Leg(id: "truck", style: .current, coordinates: match.coordinates)
                }
            } else if Self.distance(driver, next) > Self.arrivalRadius {
                wantedTruckTarget = target
                leg = Leg(id: "truck", style: .currentApproximate, coordinates: [driver, next])
                if let settings, shouldRequestTruckLeg(target: target, from: driver) {
                    jobs.insert(Job(key: "truck|" + target, from: driver, to: next,
                                    settings: settings, truckTarget: target), at: 0)
                }
            }
        }
        truckLeg = leg

        // Every leg still wanted is in `jobs`, queued already or not;
        // dequeue() drops anything that has fallen out of it.
        wantedKeys = Set(jobs.filter { $0.truckTarget == nil }.map(\.key))
        jobs.forEach(enqueue)
    }

    private func shouldRequestTruckLeg(target: String, from here: CLLocationCoordinate2D) -> Bool {
        let key = "truck|" + target
        if queuedKeys.contains(key) { return false }
        if let until = retryAt[key], until > Date() {
            scheduleWakeup(at: until)
            return false
        }
        // A new stop, or no road for this one yet: ask now.
        guard truckRoad?.target == target else { return true }
        // Same stop, and the truck has left the road it was given: ask again
        // only once the wait is up and it has actually moved on.
        guard Date().timeIntervalSince(truckRequestedAt) >= truckBackoff else { return false }
        if let origin = truckRequestOrigin, Self.distance(origin, here) < Self.rerequestMinMove { return false }
        return true
    }

    private func enqueue(_ job: Job) {
        guard !queuedKeys.contains(job.key) else { return }
        if let until = retryAt[job.key], until > Date() {
            scheduleWakeup(at: until)
            return
        }
        queuedKeys.insert(job.key)
        // The truck's leg jumps the queue - it's the one the driver needs.
        if job.truckTarget != nil { queue.insert(job, at: 0) } else { queue.append(job) }
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, isActive, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                // Wait out a throttle BEFORE choosing the next job, so the
                // choice (and the paused check) reflects the state at send time.
                if let wait = self?.throttledUntil.timeIntervalSinceNow, wait > 0 {
                    try? await Task.sleep(until: .now + .seconds(wait), clock: .continuous)
                }
                guard let job = self?.dequeue() else { break }
                await self?.fetch(job)
                // Paced, so a long route never bursts requests at Apple.
                try? await Task.sleep(until: .now + .milliseconds(300), clock: .continuous)
            }
            self?.worker = nil
        }
    }

    /// Next job still worth asking for. Returns nil while paused, leaving
    /// the queue for setActive(true) to resume.
    private func dequeue() -> Job? {
        while isActive, !queue.isEmpty {
            let job = queue.removeFirst()
            if isStillWanted(job) { return job }
            queuedKeys.remove(job.key)
        }
        return nil
    }

    private func isStillWanted(_ job: Job) -> Bool {
        guard let target = job.truckTarget else { return wantedKeys.contains(job.key) }
        guard target == wantedTruckTarget else { return false }
        // One bad fix (an overpass, a parallel street) can make the truck
        // look off its line for a moment. Back on it now: nothing to ask.
        if let road = truckRoad, road.target == target, let driver,
           Self.remainder(of: road, from: driver) != nil {
            return false
        }
        return true
    }

    private func fetch(_ job: Job) async {
        defer { queuedKeys.remove(job.key) }

        // The truck's leg starts where the truck is now, not where it was
        // when the request was queued.
        let origin = job.truckTarget != nil ? (driver ?? job.from) : job.from

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: job.to))
        request.transportType = .automobile
        // Same preferences as NavigationSession, so the overview never shows
        // a different road than the one navigation will then guide along.
        request.tollPreference = job.settings.avoidTolls ? .avoid : .any
        request.highwayPreference = job.settings.avoidHighways ? .avoid : .any

        if let target = job.truckTarget {
            // Counted when actually sent, not when queued: each re-ask for the
            // same stop doubles the wait before the next one.
            truckBackoff = truckRequestTarget == target
                ? min(truckBackoff * 2, Self.truckBackoffMax)
                : Self.truckBackoffStart
            truckRequestTarget = target
            truckRequestedAt = Date()
            truckRequestOrigin = origin
        }

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let road = response.routes.first?.polyline.coordinates, road.count > 1 else {
                retryLater(job, after: job.truckTarget == nil ? Self.noRouteRetry : Self.retryMax)
                return
            }
            retryAt[job.key] = nil
            retryDelay[job.key] = nil
            if let target = job.truckTarget {
                // The stop was completed or reordered while this was in flight.
                guard target == wantedTruckTarget else { return }
                truckRoad = TruckRoad(target: target, coordinates: road)
            } else {
                Self.legCache[job.key] = road
            }
            rebuild()
        } catch let error as MKError where error.code == .loadingThrottled {
            throttledUntil = Date().addingTimeInterval(Self.throttleBackoff)
            retryLater(job, after: Self.throttleBackoff)
        } catch let error as MKError where error.code == .directionsNotFound || error.code == .placemarkNotFound {
            retryLater(job, after: job.truckTarget == nil ? Self.noRouteRetry : Self.retryMax)
        } catch {
            // Transient (no signal, a server hiccup): retry with a growing delay.
            let delay = min((retryDelay[job.key] ?? Self.retryStart / 2) * 2, Self.retryMax)
            retryDelay[job.key] = delay
            retryLater(job, after: delay)
        }
    }

    private func retryLater(_ job: Job, after delay: TimeInterval) {
        let until = Date().addingTimeInterval(delay)
        retryAt[job.key] = until
        scheduleWakeup(at: until)
    }

    /// Retries fire even when the truck is parked and nothing else would
    /// call rebuild() - otherwise a leg that failed on a weak signal stays
    /// dashed long after the signal comes back. Sleeps on the continuous
    /// clock, which keeps counting while the phone is asleep.
    private func scheduleWakeup(at date: Date) {
        // A wakeupAt already in the past is stale (its task is still asleep)
        // and must not block a new one.
        guard date < wakeupAt || wakeupAt <= Date() else { return }
        wakeupAt = date
        wakeup?.cancel()
        wakeup = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow) + 0.5
            try? await Task.sleep(until: .now + .seconds(delay), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.wakeupAt = .distantFuture
            self?.rebuild()
        }
    }

    /// Where the truck sits on `road`: the part still ahead of it (starting
    /// at the truck), how far along the road it is, and how much is left -
    /// or nil when it's too far from the road to trust (it has left it).
    /// Searches near the last match first, so a road passing close to itself
    /// can't capture the line when a fix wobbles.
    private static func remainder(
        of road: TruckRoad,
        from truck: CLLocationCoordinate2D
    ) -> (coordinates: [CLLocationCoordinate2D], segment: Int, along: CLLocationDistance, remaining: CLLocationDistance)? {
        let points = road.coordinates
        guard points.count > 1 else { return nil }
        let lastSegment = points.count - 2
        let low = min(max(road.progress - 2, 0), lastSegment)
        var high = min(max(road.progress, low), lastSegment)
        let limit = road.along[low] + matchLookahead
        while high < lastSegment, road.along[high + 1] <= limit { high += 1 }

        var match = nearestSegment(on: points, to: truck, in: low...high)
        if match.distance > offRouteTolerance {
            match = nearestSegment(on: points, to: truck, in: 0...lastSegment)
        }
        guard match.distance <= offRouteTolerance else { return nil }

        let along = road.along[match.segment] + distance(points[match.segment], match.point.coordinate)
        let remaining = max(0, (road.along.last ?? 0) - along)
        return ([truck, match.point.coordinate] + points[(match.segment + 1)...], match.segment, along, remaining)
    }

    private static func nearestSegment(
        on road: [CLLocationCoordinate2D],
        to truck: CLLocationCoordinate2D,
        in segments: ClosedRange<Int>
    ) -> (segment: Int, point: MKMapPoint, distance: CLLocationDistance) {
        let here = MKMapPoint(truck)
        var best = (segment: segments.lowerBound, point: here, distance: CLLocationDistance.greatestFiniteMagnitude)
        for index in segments {
            let a = MKMapPoint(road[index])
            let b = MKMapPoint(road[index + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var t = lengthSquared > 0 ? ((here.x - a.x) * dx + (here.y - a.y) * dy) / lengthSquared : 0
            t = min(max(t, 0), 1)
            let projected = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = here.distance(to: projected)
            if distance < best.distance { best = (index, projected, distance) }
        }
        return best
    }

    private static func prefsKey(_ settings: NavigationSettings) -> String {
        "tolls\(settings.avoidTolls ? 0 : 1)-hwy\(settings.avoidHighways ? 0 : 1)"
    }

    private static func key(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f", c.latitude, c.longitude)
    }

    fileprivate static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        MKMapPoint(a).distance(to: MKMapPoint(b))
    }
}

struct DriverMapView: View {

    @StateObject private var vm = DriverMapViewModel()
    @StateObject private var overview = RouteOverviewPlanner()
    @Environment(\.scenePhase) private var scenePhase
    @State private var mapVisible = false

    /// Height (from the bottom safe area) of any card the parent lays
    /// over this map - e.g. DriverDashboardView's status card. The
    /// control column lifts above it so the locate/zoom buttons are
    /// never swallowed by the drawer. 0 when nothing overlays the map.
    var bottomInset: CGFloat = 0

    var body: some View {
        ZStack {
            mapLayer
                .ignoresSafeArea()

            // mapControlColumn/stopSheet/waitingForGPSBanner deliberately
            // do NOT ignore the safe area - the map filling the whole
            // screen is correct, but UI overlays need the safe-area
            // padding to stay clear of the tab bar. Applying
            // ignoresSafeArea() to this entire ZStack (old code) made
            // the banner lose that padding and render on top of the
            // tab bar instead of above it.
            mapControlColumn
            stopSheet

            if let trackingError = LocationService.shared.trackingError {
                gpsBanner(text: trackingError, color: .red)
            } else if vm.driverCoordinate == nil {
                gpsBanner(
                    text: DriverSession.shared.activeShift == nil
                        ? "Start your shift to begin live tracking."
                        : "Waiting for GPS…",
                    color: Color("WRThemeGold")
                )
            }
        }
    }

    // Shown either while waiting for the first GPS fix (normal, gold)
    // or when tracking has genuinely broken - permission revoked, a
    // real CLError - partway through a shift (a real problem, red, so
    // it reads as different from "just starting up").
    private func gpsBanner(text: String, color: Color) -> some View {
        // TOP-anchored, not bottom.
        //
        // The banner used to sit at the bottom of the map with 40pt of
        // padding, which was fine when the map was the whole screen.
        // The driver dashboard now lays a status card over the bottom
        // of that same map, so the two were drawing on top of each
        // other - "Start your shift to begin live tracking" printed
        // straight through the next stop's name and address.
        //
        // The top is genuinely free: the only thing up here is the
        // locate button in the corner, which this clears with a 56pt
        // offset. safeAreaPadding keeps it out of the status bar, since
        // the map itself is deliberately full-bleed.
        VStack {
            Text(text)
                .font(.footnote.bold())
                .foregroundColor(.black)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(color)
                .clipShape(Capsule())
                .shadow(radius: 6)
                .padding(.horizontal, 24)
                .padding(.top, 56)
            Spacer()
        }
        .safeAreaPadding(.top)
    }

    // Route order, not whatever order Firestore happened to return -
    // this is what the pin numbers and the polyline are both drawn
    // from, so "stop 4" on the map is the same stop 4 the driver sees
    // in the Route list.
    // Sorted once as it arrives (see DriverMapViewModel.observeStops)
    // rather than re-sorting on every render pass.
    private var orderedStops: [Stop] { vm.stops }

    // MARK: - MAP LAYER
    // Numbered pins + a connecting line - the same inRoute-style
    // "see your whole run at a glance" treatment LiveFleetMapView
    // already gives the owner's fleet view, now on the driver's own
    // map too instead of unlabeled dots.
    private var mapLayer: some View {
        Map(position: $vm.cameraPosition) {
            UserAnnotation()

            // Road-following, not straight lines - see RouteOverviewPlanner.
            // Later legs first, the truck's leg last so it draws on top.
            ForEach(overview.stopLegs) { leg in
                legOverlay(leg)
            }
            if let truckLeg = overview.truckLeg {
                legOverlay(truckLeg)
            }

            ForEach(Array(orderedStops.enumerated()), id: \.element.id) { index, stop in
                if let coordinate = stop.coordinate {
                    Annotation("", coordinate: coordinate) {
                        VStack(spacing: 2) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .frame(width: 26, height: 26)
                                .background(stop.isCompleted ? Color.green : Color("WRThemeGold"))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .opacity(stop.isCompleted ? 0.55 : 1)
                                .shadow(color: .black.opacity(0.35), radius: 4)

                            Text(stop.customerName ?? "")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Capsule())
                        }
                        .onTapGesture {
                            vm.selectedStop = stop
                        }
                    }
                }
            }
        }
        // Feeds DriverMapViewModel.visibleRegion so the zoom buttons
        // have a span to scale. cameraPosition is normally
        // .userLocation(...), which carries no region of its own -
        // without this the buttons would have nothing to work from.
        .onMapCameraChange { context in
            vm.visibleRegion = context.region
        }
        .onReceive(vm.$stops) { stops in
            overview.update(stops: stops, driver: vm.driverCoordinate)
        }
        .onReceive(vm.$driverCoordinate) { driver in
            overview.update(stops: vm.stops, driver: driver)
        }
        // The value is taken from the closure, not re-read from the session:
        // @Published delivers it before the property itself changes.
        .onReceive(CompanySession.shared.$currentCompany) { company in
            // Defaults if the company doc can't be read, the same fallback
            // NavigationSession uses - not "route nothing". Preferences are
            // in every cache key, so real settings arriving later just use
            // new keys.
            overview.update(settings: company?.navigationSettings ?? NavigationSettings())
        }
        // No directions requests while nobody can see this map - another tab
        // is showing, or the app is in the background mid-shift.
        // Visible and foreground are tracked apart: unlocking the phone while
        // another tab is showing must not wake a map nobody can see.
        .onAppear {
            mapVisible = true
            overview.setActive(scenePhase == .active)
        }
        .onDisappear {
            mapVisible = false
            overview.setActive(false)
        }
        .onChange(of: scenePhase) { _, phase in
            overview.setActive(mapVisible && phase == .active)
        }
    }

    /// The leg the truck is driving now is bold with a dark casing so it
    /// reads cleanly on the dark map. Later legs are lighter. A leg not
    /// routed yet is dashed straight - and when that's the truck's own leg
    /// it stays thick and bright, because it's the one line the driver
    /// actually needs to see from a mounted phone. Dashes use butt caps:
    /// round caps add half the line width to each end and close the gaps,
    /// and a dashed line that reads as solid would pass for a real road.
    @MapContentBuilder
    private func legOverlay(_ leg: RouteOverviewPlanner.Leg) -> some MapContent {
        switch leg.style {
        case .current:
            MapPolyline(coordinates: leg.coordinates)
                .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: leg.coordinates)
                .stroke(Color("WRThemeGold"), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        case .currentApproximate:
            MapPolyline(coordinates: leg.coordinates)
                .stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            MapPolyline(coordinates: leg.coordinates)
                .stroke(Color("WRThemeGold").opacity(0.9), style: StrokeStyle(lineWidth: 4.5, lineCap: .butt, dash: [10, 8]))
        case .upcoming:
            MapPolyline(coordinates: leg.coordinates)
                .stroke(Color("WRThemeGold").opacity(0.5), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        case .approximate:
            MapPolyline(coordinates: leg.coordinates)
                .stroke(Color("WRThemeGold").opacity(0.45), style: StrokeStyle(lineWidth: 2.5, lineCap: .butt, dash: [6, 7]))
        }
    }

    // MARK: - MAP CONTROLS (right edge)
    // A control column on the right edge rather than a single button in
    // the corner.
    //
    // The corner was wrong twice over: it sat level with the Dynamic
    // Island, which swallows touches there, and it put the one control
    // a driver uses while moving at the furthest point from their
    // thumb. Vertically centred on the right is where a hand already
    // is, and it leaves the top of the map clear for the GPS banner.
    //
    // Zoom buttons sit with it because pinching is a two-handed gesture
    // and this is used from a truck. They are not a replacement for
    // pinch - that still works - they are the one-handed version.
    private var mapControls: some View {
        VStack(spacing: 0) {
            Button {
                vm.zoom(by: 0.5)
            } label: {
                controlGlyph("plus")
            }

            Divider()
                .frame(width: 30)
                .overlay(Color.black.opacity(0.15))

            Button {
                vm.zoom(by: 2.0)
            } label: {
                controlGlyph("minus")
            }
        }
        .background(Color("WRThemeGold"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(radius: 6)
    }

    private func controlGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.black)
            .frame(width: 46, height: 44)
            .contentShape(Rectangle())
    }

    // How far up from the bottom safe area the control column sits.
    // These controls respect the safe area (they are NOT part of the
    // full-bleed map layer), so a small gap clears the tab bar; lift
    // further to clear the status card the parent overlays (bottomInset).
    private var controlColumnBottomPadding: CGFloat {
        bottomInset > 0 ? bottomInset + 12 : 16
    }

    private var mapControlColumn: some View {
        // Right edge, low where a thumb rests. Anchored to the bottom
        // (not vertically centred) with clearance below, so the status
        // card or route banner rising over the map can never swallow the
        // locate button. See mapControls for why the top corner was wrong.
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    mapControls

                    Button {
                        vm.centerOnDriver()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 46, height: 46)
                            .background(Color("WRThemeGold"))
                            .clipShape(Circle())
                            .shadow(radius: 6)
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .padding(.bottom, controlColumnBottomPadding)
    }

    // MARK: - STOP DETAIL SHEET
    private var stopSheet: some View {
        Group {
            if vm.selectedStop != nil {
                EmptyView()
                    .sheet(item: Binding<Stop?>(
                        get: { vm.selectedStop },
                        set: { vm.selectedStop = $0 }
                    )) { s in
                        DriverStopView(stop: s)
                    }
            }
        }
    }
}
