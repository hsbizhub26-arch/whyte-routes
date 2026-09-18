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
/// same service navigation uses), which throttles apps that ask too often:
/// - Stop-to-stop legs are fetched once and cached by coordinates for the
///   life of the app. They don't change as the truck moves.
/// - The truck's own leg is NOT re-requested as the truck drives along it.
///   It is trimmed to start at the truck instead, and only re-requested
///   when the truck strays off it or the next stop changes - and even then
///   no more than once every 20 seconds.
/// - Requests go one at a time, the truck's leg first, and only the next
///   `maxRoutedLegs` legs are routed. Anything not routed - not loaded yet,
///   no signal, or no road route - is drawn as a faint dashed straight
///   line, so an approximation never passes for a real road.
final class RouteOverviewPlanner: ObservableObject {

    enum Style { case current, upcoming, approximate }

    struct Leg: Identifiable {
        let id: String
        let style: Style
        let coordinates: [CLLocationCoordinate2D]
    }

    /// Drawn in order, so the truck's leg is last - on top.
    @Published private(set) var legs: [Leg] = []

    private static let maxRoutedLegs = 12
    /// How far the truck can be from its drawn leg before that leg is
    /// treated as stale. Measured to the nearest SEGMENT, not vertex -
    /// a long straight road has vertices hundreds of metres apart.
    private static let offRouteTolerance: CLLocationDistance = 120
    private static let currentLegMinInterval: TimeInterval = 20
    private static let throttleBackoff: TimeInterval = 60
    private static let failureRetry: TimeInterval = 120

    /// Shared across map instances, so re-opening the tab requests nothing.
    private static var legCache: [String: [CLLocationCoordinate2D]] = [:]

    private struct Job {
        let key: String
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
        /// Set for the truck's leg: the key of the stop it leads to.
        let currentTargetKey: String?
    }

    private var currentLeg: (targetKey: String, coordinates: [CLLocationCoordinate2D])?
    private var lastCurrentRequest = Date.distantPast

    private var queue: [Job] = []
    private var queuedKeys: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    private var throttledUntil = Date.distantPast
    private var worker: Task<Void, Never>?

    private var stops: [Stop] = []
    private var driver: CLLocationCoordinate2D?

    func update(stops: [Stop], driver: CLLocationCoordinate2D?) {
        self.stops = stops
        self.driver = driver
        rebuild()
    }

    private func rebuild() {
        // The rest of the run only: completed and skipped stops keep their
        // pins but no longer get a line.
        let remaining = stops
            .filter { !$0.isCompleted && !$0.isSkipped }
            .compactMap { $0.coordinate }

        var result: [Leg] = []

        for (index, pair) in zip(remaining, remaining.dropFirst()).enumerated() {
            let (from, to) = pair
            // Two stops at one address (e.g. front and back of a lot).
            guard Self.distance(from, to) > 5 else { continue }
            let key = Self.key(from) + ">" + Self.key(to)
            if let road = Self.legCache[key] {
                result.append(Leg(id: "leg-\(index)", style: .upcoming, coordinates: road))
            } else {
                result.append(Leg(id: "leg-\(index)", style: .approximate, coordinates: [from, to]))
                if index < Self.maxRoutedLegs {
                    enqueue(Job(key: key, from: from, to: to, currentTargetKey: nil))
                }
            }
        }

        if let driver, let next = remaining.first {
            let targetKey = Self.key(next)
            if let leg = currentLeg, leg.targetKey == targetKey,
               let ahead = Self.remainder(of: leg.coordinates, from: driver) {
                result.append(Leg(id: "current", style: .current, coordinates: ahead))
            } else {
                result.append(Leg(id: "current", style: .approximate, coordinates: [driver, next]))
                let newTarget = currentLeg?.targetKey != targetKey
                if newTarget || Date().timeIntervalSince(lastCurrentRequest) >= Self.currentLegMinInterval {
                    enqueue(Job(key: "current>" + targetKey, from: driver, to: next, currentTargetKey: targetKey))
                }
            }
        }

        legs = result
    }

    private func enqueue(_ job: Job) {
        guard !queuedKeys.contains(job.key) else { return }
        if let until = retryAfter[job.key], until > Date() { return }
        queuedKeys.insert(job.key)
        // The truck's leg jumps the queue - it is the one the driver needs.
        if job.currentTargetKey != nil { queue.insert(job, at: 0) } else { queue.append(job) }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let job = self?.dequeue() else { break }
                if let wait = self?.throttledUntil.timeIntervalSinceNow, wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                await self?.fetch(job)
                // Paced, so a long route never bursts requests at Apple.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self?.worker = nil
        }
    }

    private func dequeue() -> Job? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func fetch(_ job: Job) async {
        defer { queuedKeys.remove(job.key) }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: job.from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: job.to))
        request.transportType = .automobile
        // Same preferences as NavigationSession, so the overview never shows
        // a different road than the one navigation will then guide along.
        let settings = CompanySession.shared.currentCompany?.navigationSettings ?? NavigationSettings()
        request.tollPreference = settings.avoidTolls ? .avoid : .any
        request.highwayPreference = settings.avoidHighways ? .avoid : .any

        if job.currentTargetKey != nil { lastCurrentRequest = Date() }

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let road = response.routes.first?.polyline.coordinates, road.count > 1 else {
                retryAfter[job.key] = Date().addingTimeInterval(Self.failureRetry)
                return
            }
            if let targetKey = job.currentTargetKey {
                currentLeg = (targetKey, road)
            } else {
                Self.legCache[job.key] = road
            }
            rebuild()
        } catch {
            if (error as? MKError)?.code == .loadingThrottled {
                throttledUntil = Date().addingTimeInterval(Self.throttleBackoff)
                retryAfter[job.key] = throttledUntil
            } else {
                retryAfter[job.key] = Date().addingTimeInterval(Self.failureRetry)
            }
        }
    }

    /// The part of `road` still ahead of the truck, starting at the truck -
    /// or nil when the truck is too far from it to trust (it has left the
    /// route), which makes rebuild() request a fresh one.
    private static func remainder(
        of road: [CLLocationCoordinate2D],
        from truck: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D]? {
        guard road.count > 1 else { return nil }
        let here = MKMapPoint(truck)
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        var bestSegment = 0
        var bestPoint = here

        for index in 0..<(road.count - 1) {
            let a = MKMapPoint(road[index])
            let b = MKMapPoint(road[index + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var t = lengthSquared > 0 ? ((here.x - a.x) * dx + (here.y - a.y) * dy) / lengthSquared : 0
            t = min(max(t, 0), 1)
            let projected = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = here.distance(to: projected)
            if distance < bestDistance {
                bestDistance = distance
                bestSegment = index
                bestPoint = projected
            }
        }

        guard bestDistance <= offRouteTolerance else { return nil }
        return [truck, bestPoint.coordinate] + road[(bestSegment + 1)...]
    }

    private static func key(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f", c.latitude, c.longitude)
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        MKMapPoint(a).distance(to: MKMapPoint(b))
    }
}

struct DriverMapView: View {

    @StateObject private var vm = DriverMapViewModel()
    @StateObject private var overview = RouteOverviewPlanner()

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
            // The leg the truck is driving now is bold with a dark casing so
            // it reads cleanly on the dark map; later legs are lighter; any
            // leg not routed yet is a faint dashed straight line.
            ForEach(overview.legs) { leg in
                switch leg.style {
                case .current:
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(Color("WRThemeGold"), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                case .upcoming:
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(Color("WRThemeGold").opacity(0.5), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                case .approximate:
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(Color("WRThemeGold").opacity(0.45), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 7]))
                }
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
