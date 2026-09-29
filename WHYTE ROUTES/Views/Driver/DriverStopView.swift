import SwiftUI
import MapKit
import Combine

@MainActor
final class DriverStopViewModel: ObservableObject {

    @Published var stop: Stop
    @Published var isCompleting = false
    /// Set when marking the stop completed failed to reach Firestore.
    /// Shown under the button - completing a stop is the one action a
    /// driver cannot verify by looking out of the window.
    @Published var completionError: String?
    @Published var routeCompleted = false
    @Published var etaMinutes: Int?

    private let routeService = RouteService.shared
    private let session = DriverSession.shared
    // STORED, not constructed at the call site. closeOut() does its
    // work inside a Firestore completion handler that captures
    // [weak self], so a `TrackingLinkRepository().closeOut(...)`
    // temporary was already deallocated by the time the callback ran -
    // self was nil, the loop never executed, and the link was never
    // closed. The compiler says so outright ("weak reference will
    // always be nil because the referenced object is deallocated
    // here"), and the consequence was the exact thing that must not
    // happen: a customer whose service is finished keeps watching the
    // truck drive on to everybody else's homes for the rest of the
    // shift.
    private let trackingRepo = TrackingLinkRepository()

    // GPS older than this is treated as unusable for an ETA
    // notification - better to send nothing than tell a customer
    // "10 minutes away" based on where the driver was half an hour
    // ago. Threshold flags are local-only "don't bother calling
    // again this session" hints; the real once-only guarantee is
    // sendCustomerNotification's server-side idempotency check, so a
    // second device or a relaunch can never cause a duplicate.
    private static let maxLocationAge: TimeInterval = 5 * 60
    private var eta10Notified = false
    private var etaRefreshTimer: Timer?

    private var cancellables = Set<AnyCancellable>()

    init(stop: Stop) {
        self.stop = stop
        observeGeofenceArrival()
    }

    deinit {
        etaRefreshTimer?.invalidate()
    }

    // Auto-arrival: LocationService flips hasArrivedAtTarget when the
    // driver physically reaches the stop, and this turns that into the
    // real status transition. Saves a tap in the cold with gloves on,
    // and stamps arrivedAt at the moment they actually got there
    // rather than whenever they got around to pressing the button -
    // which is what the on-site duration is measured from.
    //
    // Only ever promotes enRoute -> arrived. It never touches a stop
    // that's already arrived/completed, and never skips the en-route
    // step, so it can't fire a customer's arrival text for a stop the
    // driver hasn't started driving to (e.g. a stop that happens to be
    // near where they parked overnight).
    /// Every other stop still worth distinguishing from this one -
    /// completed stops are excluded, since a finished property behind
    /// the driver shouldn't stop the next one from registering.
    func otherStopCoordinates(excluding stop: Stop) -> [CLLocationCoordinate2D] {
        session.activeStops
            .filter { $0.id != stop.id && !$0.isCompleted }
            .compactMap { $0.coordinate }
    }

    private func observeGeofenceArrival() {
        LocationService.shared.$hasArrivedAtTarget
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.jobStatus == .enRoute else { return }
                    await self.markArrived()
                }
            }
            .store(in: &cancellables)
    }

    // Recomputes ETA (and re-checks the 15/10 min thresholds) every
    // 60s while actually driving to this stop - a one-time ETA
    // calculated when the screen first opened would never notice the
    // driver getting closer. Stops itself once arrived/completed,
    // since ETA-to-a-stop stops meaning anything at that point.
    func startETARefreshTimer() {
        stopETARefreshTimer()
        etaRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            // self is unwrapped HERE, outside the Task, and jobStatus is
            // read INSIDE it. Both placements matter:
            //
            //  - unwrapping outside means the weak optional is never
            //    read from concurrently-executing code, which is the
            //    original Swift 6 error;
            //  - reading jobStatus inside means a MainActor-isolated
            //    property is only touched on the MainActor. Reading it
            //    out here, in the timer's non-isolated closure, is what
            //    produced "main actor-isolated property 'jobStatus'
            //    can not be referenced from a Sendable closure".
            //
            // The capture stays WEAK. A strong [self] silences both
            // warnings, but the Timer retains the closure, the closure
            // retains the view model, and the view model retains the
            // Timer - so deinit never runs, invalidate() is never
            // called, and every stop screen a driver opens leaves a
            // timer firing loadETA() every 60s for the life of the app.
            // Forty stops on an overnight route means forty live timers
            // and forty recurring directions requests.
            guard let self else { return }
            Task { @MainActor in
                guard self.jobStatus == .enRoute else {
                    self.stopETARefreshTimer()
                    return
                }
                self.loadETA()
            }
        }
    }

    func stopETARefreshTimer() {
        etaRefreshTimer?.invalidate()
        etaRefreshTimer = nil
    }

    var route: Route? { session.assignedRoute }

    var jobStatus: JobStatus {
        JobStatus(rawValue: stop.status) ?? .scheduled
    }

    /// When to run the at-property timer, or nil for no timer.
    ///
    /// Guards on STATUS, not just on arrivedAt being present. A stop can
    /// carry an old arrivedAt while it is merely scheduled - the owner's
    /// reset in EditRouteView writes through setData(merge: true), and
    /// toDict() omits nil fields, so the reset never actually deletes
    /// the timestamp - and the stop screen then counted up from it:
    /// "At property: 163:49:38" on a driveway nobody was standing in.
    ///
    /// Deliberately no age ceiling. A crew can hold a commercial lot for
    /// the whole of a 20-hour storm; the owner's fleet map has no cap
    /// either, and the two should agree. An arrived stop showing a huge
    /// number is also the one visible sign that a visit was never
    /// closed out, which a silent cap would hide.
    var atPropertyStart: Date? {
        guard jobStatus == .arrived else { return nil }
        return stop.arrivedAt
    }

    /// False once arrived or completed - or while a completion is still
    /// saving - so the navigation screen hides its fallback button
    /// instead of offering a tap that does nothing, or worse.
    var canMarkArrived: Bool {
        !isCompleting && !stop.isCompleted && jobStatus != .arrived
    }

    /// "Stop 12 of 47" - position within the route's stops in their
    /// assigned order, not just however many are left.
    var stopPosition: (current: Int, total: Int)? {
        let ordered = session.activeStops.sorted { $0.order < $1.order }
        guard let index = ordered.firstIndex(where: { $0.id == stop.id }) else { return nil }
        return (index + 1, ordered.count)
    }

    var nextStopPreview: Stop? {
        session.activeStops
            .filter { !$0.isCompleted && $0.id != stop.id }
            .sorted { $0.order < $1.order }
            .first
    }

    // MARK: - Status transitions (explicit driver-triggered, not
    // automatic GPS proximity - see NotificationService for why)
    func startDriving() async {
        guard let route else { return }
        stop.status = JobStatus.enRoute.rawValue
        stop.enRouteAt = Date()
        await routeService.updateStop(routeId: route.id, stop: stop)
        // No customer text here. "On the way" was retired along with
        // the 15-minute ETA and "arrived" - three of the five texts a
        // customer used to get per stop, for a stop they might still
        // be ninth in line for. The status still moves, the owner's
        // board and the tracking page both still update live; what
        // stopped is the phone buzzing about it.
    }

    func markArrived() async {
        guard let route else { return }
        // Arriving is idempotent. Three paths land here now - the
        // geofence (observeGeofenceArrival), the button on this screen,
        // and the fallback button on the navigation screen - so without
        // this guard a driver who taps "I've Arrived" seconds after the
        // geofence already fired restamps arrivedAt and resets the
        // at-property timer to zero, losing the minutes they were
        // actually on the driveway.
        //
        // isCompleting closes a second hole: markCompleted only commits
        // `stop` once Firestore confirms, so on a weak signal the stop
        // still reads en route while its completion is in flight. An
        // arrival queued in that window lands AFTER the completed write
        // and leaves the stop arrived-but-not-completed.
        guard !isCompleting, !stop.isCompleted, jobStatus != .arrived else { return }
        stop.status = JobStatus.arrived.rawValue
        stop.arrivedAt = Date()
        await routeService.updateStop(routeId: route.id, stop: stop)
        // Retired, same as enRoute above. "Arrived" landed seconds
        // before "completed" on a driveway that takes four minutes,
        // so the customer got two texts for one visit.
    }

    // MARK: - MARK STOP COMPLETED
    func markCompleted() async {
        guard let route else { return }

        isCompleting = true
        completionError = nil

        // Built as a COPY and only committed to `stop` once the write
        // succeeds. Mutating self.stop first made the row render as
        // completed the instant it was tapped, so a failed write left
        // a stop that looked done to the driver, was still scheduled
        // in Firestore, and would be silently re-served or skipped.
        var updated = stop
        updated.isCompleted = true
        updated.status = JobStatus.completed.rawValue
        updated.completedAt = Date()

        let saved = await routeService.updateStop(routeId: route.id, stop: updated)
        guard saved else {
            isCompleting = false
            completionError = "Couldn't mark this stop completed - check your connection and tap again."
            return
        }
        stop = updated

        // Only now, with the completion actually persisted: the text
        // says the service is finished, and there is no unsending it.
        await NotificationService.shared.notify(stop: stop, routeId: route.id, type: "completed")

        // This customer's service is done, so their live tracking ends
        // here: the position document is deleted and the link marked
        // complete. Without this they could keep watching the truck
        // drive on to other people's homes for the rest of the shift.
        trackingRepo.closeOut(stopId: stop.id)

        // Real bug found during a full-workday audit: nothing anywhere
        // ever marked a Route itself "completed" once every stop on it
        // was done - RouteRepository.updateStatus existed but had zero
        // callers. Without this, a driver's "fetch my current route"
        // query (which explicitly excludes status == "completed")
        // could keep matching yesterday's finished route instead of a
        // new one assigned today, since nothing ever took it out of
        // contention. Checked using this stop's own just-set value
        // plus the rest of the session's last-known stop state, not a
        // re-fetch - the snapshot listener updating activeStops with
        // THIS stop's change is async and not guaranteed to have
        // landed yet.
        let others = session.activeStops.filter { $0.id != stop.id }
        let allDone = others.allSatisfy { $0.isCompleted }
        if allDone {
            routeService.updateStatus(for: route.id, status: "completed")
        }

        // Auto-advance: load the next stop into this same screen so
        // the driver can tap Navigate immediately - no back-and-forth
        // to Dashboard and re-opening a stop required.
        if let next = others.filter({ !$0.isCompleted }).sorted(by: { $0.order < $1.order }).first {
            stop = next
            etaMinutes = nil
            LocationService.shared.setArrivalTarget(
                lat: next.latitude,
                lng: next.longitude,
                otherStops: otherStopCoordinates(excluding: next)
            )
            loadETA()
        } else {
            routeCompleted = true
        }

        isCompleting = false
    }

    /// Driver's own ETA to the current stop - on-device MKDirections,
    /// no paid routing API, no network cost. Separate from (and much
    /// simpler than) the customer-facing ETA notifications, which
    /// remain deferred - this is just what the driver sees for
    /// themselves.
    func loadETA() {
        guard let destination = stop.coordinate,
              let origin = LocationService.shared.currentLocation else {
            etaMinutes = nil
            return
        }

        // Stale GPS must never produce a customer-facing ETA claim -
        // this only gates the eta10 notification trigger below,
        // not the driver's own on-screen ETA display, which stays
        // useful even with slightly old location data.
        let locationIsFresh: Bool
        if let lastUpdate = LocationService.shared.lastLocationUpdate {
            locationIsFresh = Date().timeIntervalSince(lastUpdate) <= Self.maxLocationAge
        } else {
            locationIsFresh = false
        }

        let request = MKDirections.Request()
        let sourceItem = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)))
        let destinationItem = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)))
        request.source = sourceItem
        request.destination = destinationItem
        request.transportType = .automobile

        Task {
            do {
                let eta = try await MKDirections(request: request).calculateETA()
                let minutes = Int(eta.expectedTravelTime / 60)
                await MainActor.run {
                    self.etaMinutes = minutes
                    if locationIsFresh {
                        self.checkETAThresholds(minutes)
                    }
                }
            } catch {
                await MainActor.run { self.etaMinutes = nil }
            }
        }
    }

    // The one remaining ETA text. Only meaningful while actually
    // driving to this stop - once arrived/completed, "how far away is
    // the driver" no longer applies. Threshold CROSSING only, not "is
    // currently under 10", so an ETA bouncing around 9-11 minutes
    // can't fire twice - that's what eta10Notified is for.
    //
    // The lower bound matters as much as the upper one. Without it,
    // the first ETA the app ever computes for a stop can already be
    // 3 minutes - the driver is around the corner, or the previous
    // stop was next door - and the customer gets told "approximately
    // 10 minutes away" as the truck pulls up. Under 5 minutes there
    // is no useful warning left to give, so nothing is sent.
    private func checkETAThresholds(_ minutes: Int) {
        guard jobStatus == .enRoute, let route else { return }
        guard !eta10Notified, minutes <= 10, minutes > 5 else { return }

        eta10Notified = true
        Task { await NotificationService.shared.notify(stop: stop, routeId: route.id, type: "eta10") }
    }
}

struct DriverStopView: View {

    @StateObject private var vm: DriverStopViewModel
    @StateObject private var nav = NavigationSession()
    @ObservedObject private var session = DriverSession.shared
    @ObservedObject private var access = FeatureAccessManager.shared
    @State private var showPhotoCapture = false
    @State private var proofPhotoURL: String?
    /// The map was `initialPosition:`, which means exactly what it says
    /// - it framed the stop once and then never moved again, so during
    /// navigation the driver watched their own dot walk off the edge.
    /// Bound now, so it can follow while navigating and snap back to
    /// the stop when navigation ends.
    @State private var navCamera: MapCameraPosition = .automatic

    @Environment(\.dismiss) private var dismiss

    init(stop: Stop) {
        _vm = StateObject(wrappedValue: DriverStopViewModel(stop: stop))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color("WRBlack").ignoresSafeArea()

            if vm.routeCompleted {
                routeCompletedView
            } else {
                ScrollView {
                    VStack(spacing: 20) {

                        progressBar
                        header
                        mapSection
                        primaryAction
                        // iPad without a usable GPS fix: say up front that
                        // arrival is manual. Not once arrived - by then it
                        // no longer matters. See GPSArrivalNotice.
                        if vm.jobStatus == .scheduled || vm.jobStatus == .enRoute {
                            GPSArrivalNotice()
                        }
                        // The driver-side "Text Customer" button is GONE, not
                        // hidden. Its old comment said the tracking link had
                        // "no real destination yet" - that stopped being true
                        // the moment the tracking page shipped. What makes it
                        // unrevivable is different and permanent: tracking
                        // tokens are minted SERVER-SIDE, by ensureTrackingLink
                        // inside the Cloud Function, so this app cannot
                        // construct a valid tracking URL at all. It was
                        // building one by hand against whyteroutes.app - a
                        // domain nobody owns - and shipping that string in the
                        // binary. Sending a tracking link is the owner's
                        // "Send Tracking Link" action, which goes through the
                        // function that actually owns the token.
                        // photoProofButton is optional and never blocks
                        // completion - a driver in gloves, in the dark, with
                        // dozens of driveways left before people wake up can
                        // ignore it entirely and tap straight through. It is
                        // tier-gated on canAccessProofOfWork() and only shown
                        // once actually arrived, so it costs a snow crew
                        // nothing while giving landscaping jobs (and any
                        // "you never came" dispute) a timestamped photo.
                        //
                        // One button per stage, Uber-Driver-style - only
                        // shown once actually arrived. It used to render
                        // (enabled) at every stage, including .scheduled -
                        // a driver could tap straight to Completed without
                        // ever tapping Start Driving or I've Arrived,
                        // silently skipping the en-route/arrived customer
                        // texts along with the steps themselves.
                        if vm.jobStatus == .arrived || vm.jobStatus == .completed {
                            if access.canAccessProofOfWork() {
                                photoProofButton
                            }
                            completeButton
                            completionErrorBanner
                        }

                        Spacer(minLength: 40)
                    }
                    .padding()
                    .readableContentWidth()
                }
            }

            closeButton
        }
        // FULL-SCREEN WHILE GUIDANCE IS RUNNING.
        //
        // The inline 280pt map stays exactly as it is - it is the right
        // size for looking at a stop before setting off. But once
        // turn-by-turn starts the task changes completely: the driver is
        // moving, the phone is on a mount, and they get one glance. Every
        // navigation app goes full-bleed at this moment for that reason.
        //
        // Driven off nav.isNavigating rather than its own flag, so there
        // is one source of truth: ending navigation from either screen,
        // or the session stopping on arrival, dismisses this by itself.
        .fullScreenCover(isPresented: Binding(
            get: { nav.isNavigating },
            set: { if !$0 && nav.isNavigating { nav.stop() } }
        )) {
            DriverNavigationScreen(
                nav: nav,
                stopName: vm.stop.customerName ?? "Stop",
                stopAddress: vm.stop.address,
                stopCoordinate: vm.stop.coordinate,
                stopIndex: vm.stopPosition?.current ?? 1,
                stopCount: vm.stopPosition?.total ?? 1,
                // Arriving ends navigation (the onChange on jobStatus
                // below stops it, which is what releases the voice and
                // the audio session once the crew is out of the truck),
                // so the at-property timer runs on THIS screen after
                // arrival, not on the navigation screen.
                onArrive: vm.canMarkArrived ? { Task { await vm.markArrived() } } : nil,
                onEnd: { nav.stop() },
                onComplete: {
                    nav.stop()
                    Task { await vm.markCompleted() }
                }
            )
        }
        .sheet(isPresented: $showPhotoCapture) {
            if let companyId = CompanySession.shared.currentCompanyId,
               let routeId = vm.route?.id,
               let driverId = session.driver?.id {
                PhotoProofView(
                    companyId: companyId,
                    routeId: routeId,
                    stopId: vm.stop.id,
                    driverId: driverId,
                    type: "completion",
                    onUploaded: { url in
                        proofPhotoURL = url
                        showPhotoCapture = false
                    }
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // GPS tracking itself is tied to the shift lifecycle (see
            // DriverSession.startShift/endShift) - this just tells the
            // already-running tracker what "arrived" means for this stop.
            LocationService.shared.setArrivalTarget(
                lat: vm.stop.latitude,
                lng: vm.stop.longitude,
                otherStops: vm.otherStopCoordinates(excluding: vm.stop)
            )
            vm.loadETA()
            vm.startETARefreshTimer()
            // Keep the screen awake while an active stop is open - a
            // mounted tablet/phone dimming mid-shift is exactly the
            // kind of friction this feature is meant to remove.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            vm.stopETARefreshTimer()
            nav.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // Navigation's job is done the moment the driver is there -
        // whether they arrived by the geofence firing or by tapping.
        // Without this it would keep announcing (and holding the audio
        // session) while they're out of the truck working the property.
        .onChange(of: vm.jobStatus) { _, status in
            if status != .enRoute && nav.isNavigating {
                nav.stop()
            }
        }
        // Follow the truck, rotated the way it's actually pointing,
        // while navigating - a north-up map is close to useless at a
        // junction in the dark. Back to framing the stop when
        // navigation ends.
        .onChange(of: nav.isNavigating) { _, navigating in
            withAnimation {
                navCamera = navigating
                    ? .userLocation(followsHeading: true, fallback: .automatic)
                    : stopRegion()
            }
        }
        .onAppear { navCamera = stopRegion() }
    }

    /// The static framing of this stop, used before and after
    /// navigation.
    private func stopRegion() -> MapCameraPosition {
        guard let c = vm.stop.coordinate else { return .automatic }
        return .region(
            MKCoordinateRegion(center: c, span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01))
        )
    }
}

extension DriverStopView {

    // MARK: STOP POSITION
    @ViewBuilder
    private var progressBar: some View {
        if let position = vm.stopPosition {
            Text("Stop \(position.current) of \(position.total)")
                .font(.caption.bold())
                .foregroundColor(.white.opacity(0.6))
        }
    }

    // MARK: HEADER
    private var header: some View {
        VStack(spacing: 6) {
            Text(vm.stop.customerName ?? "Customer")
                .font(.largeTitle.bold())
                .foregroundColor(Color("WRThemeGold"))

            Text(vm.stop.address)
                .foregroundColor(.white.opacity(0.8))
                .font(.headline)
                .multilineTextAlignment(.center)

            if let eta = vm.etaMinutes {
                Text("ETA \(eta) min")
                    .font(.subheadline.bold())
                    .foregroundColor(.white.opacity(0.7))
            }

            if let notes = vm.stop.driverNotes, !notes.isEmpty {
                driverNotesCallout(notes)
            }
        }
        .padding(.top, 10)
    }

    // Uber-Eats-style standing instructions - gate code, "no scrape",
    // dog in the yard. Deliberately loud (not a quiet caption line)
    // since this is the kind of thing that matters most exactly when
    // a driver is rushing and not reading closely.
    private func driverNotesCallout(_ notes: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundColor(.black)
            Text(notes)
                .font(.subheadline.bold())
                .foregroundColor(.black)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("WRThemeGold"))
        .cornerRadius(12)
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    // MARK: MAP
    @ViewBuilder
    private var mapSection: some View {
        if let coordinate = vm.stop.coordinate {
            Map(position: $navCamera) {
                // Custom gold pin, not MapKit's stock red marker - the
                // stock one is the one place left that broke the
                // black/gold branding every other pin in the app
                // already follows (see LiveFleetMapView/DriverMapView).
                Annotation("", coordinate: coordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title)
                        .foregroundColor(Color("WRThemeGold"))
                        .background(Circle().fill(.white).padding(3))
                        .shadow(color: .black.opacity(0.35), radius: 4)
                }

                // The driver's own position and the live route, shown
                // only while navigating - this map is a static preview
                // of the stop the rest of the time.
                if nav.isNavigating {
                    UserAnnotation()
                    if let polyline = nav.route?.polyline {
                        MapPolyline(polyline)
                            .stroke(Color("WRThemeGold"), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color("WRThemeGold"), lineWidth: 2)
            )
            .overlay(alignment: .top) {
                if nav.isNavigating { maneuverBanner }
            }
        } else {
            // A stop with no coordinates used to render NOTHING here,
            // and the Start Navigation button below vanished with it -
            // so a driver who tapped Start Navigation arrived at a
            // screen with an address, an "I've Arrived" button, and no
            // explanation of where the map went. Silence reads as a
            // broken app; it is actually missing data.
            //
            // It happens when a customer's address was typed by hand
            // instead of picked from the suggestions - Add Customer
            // warns about exactly this, and the warning is easy to
            // click past.
            VStack(spacing: 10) {
                Image(systemName: "mappin.slash")
                    .font(.title2)
                    .foregroundColor(Color("WRThemeGold"))
                Text("No map location for this stop")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("This customer's address was saved without a map location, so navigation can't start. Ask your dispatcher to re-enter it and pick the address from the suggestions.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color("WRThemeGold").opacity(0.4), lineWidth: 1)
            )
        }
    }

    // Sits over the map while navigating: what the next turn is, how
    // far to it, and what's left overall. Deliberately large text -
    // this is read at a glance from a mount, in the dark, moving.
    private var maneuverBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            // A glanceable arrow. Reading a sentence off a phone mount
            // at 3am with snow coming down is not the same task as
            // reading one on a desk - the shape registers before the
            // words do.
            if !nav.isRecalculating {
                Image(systemName: maneuverSymbol(nav.currentInstruction))
                    .font(.title.bold())
                    .foregroundColor(.black)
                    .frame(width: 38)
            }

            VStack(alignment: .leading, spacing: 4) {
            if nav.isRecalculating {
                Text("Rerouting…")
                    .font(.subheadline.bold())
                    .foregroundColor(.black)
            } else {
                if let distance = nav.distanceToManeuver {
                    Text(formattedDistance(distance))
                        .font(.title3.bold())
                        .foregroundColor(.black)
                }
                Text(nav.currentInstruction ?? "Starting navigation…")
                    .font(.headline)
                    .foregroundColor(.black)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let remaining = nav.remainingDistance, let eta = nav.remainingTime {
                Text("\(formattedDistance(remaining)) · \(Int(eta / 60)) min to stop")
                    .font(.caption)
                    .foregroundColor(.black.opacity(0.7))
            }

            if let error = nav.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color("WRThemeGold"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(8)
    }

    private func formattedDistance(_ metres: CLLocationDistance) -> String {
        metres >= 1000
            ? String(format: "%.1f km", metres / 1000)
            : "\(Int(metres)) m"
    }

    /// Maps MapKit's instruction text onto an SF Symbol.
    ///
    /// MapKit does not hand back a maneuver TYPE on MKRoute.Step - only
    /// the sentence - so matching on the text is the available option.
    /// Order matters: "slight left" has to be tested before "left", or
    /// every slight turn renders as a hard one.
    private func maneuverSymbol(_ instruction: String?) -> String {
        let s = (instruction ?? "").lowercased()
        if s.contains("u-turn") || s.contains("u turn") { return "arrow.uturn.up" }
        if s.contains("roundabout") || s.contains("rotary") { return "arrow.triangle.2.circlepath" }
        if s.contains("slight left") { return "arrow.up.left" }
        if s.contains("slight right") { return "arrow.up.right" }
        if s.contains("sharp left") { return "arrow.turn.up.left" }
        if s.contains("sharp right") { return "arrow.turn.up.right" }
        if s.contains("exit") { return "arrow.up.right" }
        if s.contains("merge") { return "arrow.merge" }
        if s.contains("arriv") || s.contains("destination") { return "mappin.circle.fill" }
        if s.contains("left") { return "arrow.turn.up.left" }
        if s.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }

    // MARK: ACTION BUTTONS
    // Always-visible escape. This screen is a sheet, whose only other
    // way out is a swipe-down grabber that's easy to miss - and if the
    // driver started navigation and it's busy, they could feel trapped.
    // Ends navigation first if it's running, then dismisses the sheet.
    private var closeButton: some View {
        Button {
            if nav.isNavigating { nav.stop() }
            dismiss()
        } label: {
            Image(systemName: "chevron.down")
                .font(.headline.bold())
                .foregroundColor(.white)
                .padding(12)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .padding(.leading, 16)
        .padding(.top, 8)
    }

    // MARK: PRIMARY ACTION - one button per stage, Uber-Driver style.
    //
    // Previously this was TWO stacked gold buttons that looked
    // identical but did different jobs: "Start Driving" (mark en route
    // + text the customer) and "Start Navigation" (open the in-app
    // turn-by-turn). A driver at 5am can't tell a status button from a
    // maps button when both say "Start ___" in the same colour, so the
    // two are merged: starting to drive and getting directions are one
    // action here, exactly as they always are in real life. In-app
    // navigation stays the only navigation - leaving the route inside
    // the app keeps the stop list, arrival geofence, customer tracking
    // link and shift timer all live, none of which survive a bounce out
    // to Apple Maps.
    @ViewBuilder
    private var primaryAction: some View {
        VStack(spacing: 16) {
            switch vm.jobStatus {
            case .scheduled:
                // ONE tap does the whole "I'm starting this stop"
                // gesture: clock in if not already on shift (which
                // starts GPS tracking, the dispatcher's live map, the
                // customer tracking page and the time report), mark the
                // stop en route (texting the customer "on my way"), and
                // open navigation. A driver never has to find a separate
                // Start Shift button first.
                Button {
                    Task {
                        if DriverSession.shared.activeShift == nil {
                            _ = await DriverSession.shared.startShift()
                        }
                        await vm.startDriving()
                        if let coordinate = vm.stop.coordinate {
                            nav.start(to: coordinate)
                        }
                    }
                } label: {
                    Label("Start Driving", systemImage: "car.fill")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color("WRThemeGold"))
                        .cornerRadius(14)
                }

            case .enRoute:
                // Now that they're on the way, arriving is the primary
                // action. Navigation becomes a secondary control so a
                // driver who closed the map can pull directions back
                // without re-triggering the customer text.
                Button {
                    Task { await vm.markArrived() }
                } label: {
                    Label("I've Arrived", systemImage: "mappin.circle.fill")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color("WRThemeGold"))
                        .cornerRadius(14)
                }
                // Same rule as the navigation screen's fallback: not while
                // a completion is still saving (see markArrived).
                .disabled(!vm.canMarkArrived)

                if let coordinate = vm.stop.coordinate {
                    Button {
                        if nav.isNavigating { nav.stop() } else { nav.start(to: coordinate) }
                    } label: {
                        Label(
                            nav.isNavigating ? "End Navigation" : "Resume Navigation",
                            systemImage: nav.isNavigating ? "xmark.circle" : "location.north.circle"
                        )
                        .font(.subheadline.bold())
                        .foregroundColor(nav.isNavigating ? .red : Color("WRThemeGold"))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke((nav.isNavigating ? Color.red : Color("WRThemeGold")).opacity(0.6), lineWidth: 1)
                        )
                    }
                }

            case .arrived, .completed:
                EmptyView()
            }

            // Surfaced here rather than only in the maneuver banner:
            // without it, tapping the button with no GPS fix yet did
            // nothing visible at all, which reads as a dead button.
            if let error = nav.errorMessage, !nav.isNavigating {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let arrivedAt = vm.atPropertyStart {
                TimerPill(arrivedAt: arrivedAt)
            }
        }
    }

    // MARK: PHOTO PROOF (optional - not required to complete, but
    // encouraged for dispute resolution / proof of work)
    private var photoProofButton: some View {
        Button {
            showPhotoCapture = true
        } label: {
            HStack {
                Image(systemName: proofPhotoURL != nil ? "checkmark.circle.fill" : "camera.fill")
                Text(proofPhotoURL != nil ? "Photo Added" : "Add Photo Proof")
            }
            .font(.headline)
            .foregroundColor(proofPhotoURL != nil ? .green : .white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.25))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color("WRThemeGold"), lineWidth: 1)
            )
        }
    }

    // MARK: COMPLETE BUTTON
    private var completeButton: some View {
        Button {
            Task {
                // Was `proofPhotoURL = nil` - which threw away the proof
                // the driver had just taken at the exact moment the stop
                // was completed, so the button flipped from "Photo Added"
                // back to "Add Photo Proof". The photo and its metadata
                // are already in Storage/Firestore by then; this state is
                // only the button's label.
                await vm.markCompleted()
            }
        } label: {
            HStack {
                if vm.isCompleting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Mark Completed")
                }
            }
            .font(.headline)
            .foregroundColor(.black)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color("WRThemeGold"))
            .cornerRadius(14)
        }
        .disabled(vm.isCompleting || vm.stop.isCompleted)
        .opacity(vm.stop.isCompleted ? 0.4 : 1)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var completionErrorBanner: some View {
        if let message = vm.completionError {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundColor(.orange)
                .padding(.top, 6)
        }
    }

    // MARK: ROUTE COMPLETED
    private var routeCompletedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Route Completed 🎉")
                .font(.title.bold())
                .foregroundColor(Color("WRThemeGold"))

            Text("All stops finished. Head back to Dashboard to end your shift.")
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

