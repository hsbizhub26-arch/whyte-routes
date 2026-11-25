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
    /// Route Memory: the driver's optional "why did this take longer" chip.
    @Published var reasonCode: String?
    @Published var reasonText: String = ""

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
    private let history = ServiceHistoryRepository.shared

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
            .filter { $0.id != stop.id && $0.isPending }
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

    // MARK: Route Memory (reason chips)

    /// True once the time on this property passes what was predicted.
    func isOverPrediction(at now: Date = Date()) -> Bool {
        guard let start = atPropertyStart else { return false }
        return now.timeIntervalSince(start) > RouteMemoryService.shared.prediction(for: stop).sec
    }

    /// Would finishing right now be flagged? Same rule the server applies.
    func willFlagNow(at now: Date = Date()) -> Bool {
        guard let start = atPropertyStart else { return false }
        let s = RouteMemoryService.shared.stats(for: stop)
        return RouteMemoryCore.willFlag(elapsedSec: now.timeIntervalSince(start),
                                        avgSec: s?.avgDurationSec, visitCount: s?.visitCount ?? 0)
    }

    func chooseReason(_ code: String, text: String?) {
        reasonCode = code
        if code != "other" { reasonText = "" }
        history.recordReason(visitId: stop.openVisitId, code: code, text: text ?? reasonText)
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
            .filter { $0.isPending && $0.id != stop.id }
            .sorted { $0.order < $1.order }
            .first
    }

    // MARK: - Status transitions (explicit driver-triggered, not
    // automatic GPS proximity - see NotificationService for why)
    func startDriving() async {
        guard let route else { return }
        let now = Date()
        // Decided on the stop as it is BEFORE this event - see
        // ServiceHistoryRepository.visitId.
        let visit = history.visitId(for: stop, event: .enRoute, at: now)
        stop.status = JobStatus.enRoute.rawValue
        stop.enRouteAt = now
        stop.openVisitId = visit.id
        // Phase 5: returns within seconds even with no signal (the write
        // waits on the phone and sends itself later).
        _ = await routeService.saveStop(routeId: route.id, stop: stop)
        // Re-tapping Start Driving on a visit already under way must
        // not try to overwrite its first on-the-way time (the rules
        // would refuse it anyway); only a new visit records it.
        if visit.isNew {
            history.record(.enRoute, stop: stop, routeId: route.id, routeName: route.name,
                           visitId: visit.id, isNew: true, at: now)
        }
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
        let now = Date()
        let visit = history.visitId(for: stop, event: .arrived, at: now)
        stop.status = JobStatus.arrived.rawValue
        stop.arrivedAt = now
        stop.openVisitId = visit.id
        _ = await routeService.saveStop(routeId: route.id, stop: stop)
        history.record(.arrived, stop: stop, routeId: route.id, routeName: route.name,
                       visitId: visit.id, isNew: visit.isNew, at: now)
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
        let now = Date()
        let visit = history.visitId(for: stop, event: .completed, at: now)
        var updated = stop
        updated.isCompleted = true
        updated.status = JobStatus.completed.rawValue
        updated.completedAt = now
        updated.openVisitId = visit.id

        // Phase 5: with no signal the completion is kept on the phone and
        // sent when signal returns. The completion TEXT needs the server
        // copy (the Cloud Function reads the stop), so in that case it is
        // sent from onSynced, once the server actually has it.
        let routeId = route.id
        let outcome = await routeService.saveStop(routeId: routeId, stop: updated) { synced in
            guard synced else { return }
            Task { await NotificationService.shared.notify(stop: updated, routeId: routeId, type: "completed") }
        }
        guard outcome != .failed else {
            isCompleting = false
            completionError = "Couldn't mark this stop completed - check your connection and tap again."
            return
        }
        stop = updated

        // The permanent record of this visit: done time plus where the
        // truck actually was. Written before anything else below so a
        // failure in the text or link close-out can't cost it.
        history.record(.completed, stop: updated, routeId: route.id, routeName: route.name,
                       visitId: visit.id, isNew: visit.isNew, at: now)

        // Only now, with the completion actually persisted: the text
        // says the service is finished, and there is no unsending it.
        if outcome == .synced {
            await NotificationService.shared.notify(stop: stop, routeId: route.id, type: "completed")
        }

        // This customer's service is done, so their live tracking ends
        // here: the position document is deleted and the link marked
        // complete. Without this they could keep watching the truck
        // drive on to other people's homes for the rest of the shift.
        trackingRepo.closeOut(stopId: stop.id)

        advanceToNextPendingStop(in: route)

        isCompleting = false
    }

    // MARK: - SKIP STOP
    // For a stop the driver can't or won't service (blocked driveway,
    // customer cancelled, out of time). Without this a bypassed stop
    // sat at the head of the queue and every customer behind it kept a
    // count that included it. No text is sent: nothing was done.
    func markSkipped() async {
        guard let route else { return }

        isCompleting = true
        completionError = nil

        // Same discipline as markCompleted: persist a COPY first and only
        // commit it once Firestore confirms. Status goes back to
        // scheduled so a skipped en-route stop doesn't keep an en-route
        // badge.
        let now = Date()
        let visit = history.visitId(for: stop, event: .skipped, at: now)
        var updated = stop
        updated.isSkipped = true
        updated.status = JobStatus.scheduled.rawValue
        updated.openVisitId = visit.id

        let outcome = await routeService.saveStop(routeId: route.id, stop: updated)
        guard outcome != .failed else {
            isCompleting = false
            completionError = "Couldn't skip this stop - check your connection and tap again."
            return
        }
        stop = updated

        // A skip is history too: "we came and couldn't do it" is part
        // of the record an owner bills (or doesn't bill) from.
        history.record(.skipped, stop: updated, routeId: route.id, routeName: route.name,
                       visitId: visit.id, isNew: visit.isNew, at: now)

        // This customer is no longer being served: end their live link
        // without marking it completed.
        trackingRepo.closeOutSkipped(stopId: stop.id)

        advanceToNextPendingStop(in: route)

        isCompleting = false
    }

    // Shared tail of markCompleted and markSkipped.
    private func advanceToNextPendingStop(in route: Route) {
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
        // landed yet. A skipped stop counts as finished here too.
        let others = session.activeStops.filter { $0.id != stop.id }
        let allDone = others.allSatisfy { !$0.isPending }
        if allDone {
            routeService.updateStatus(for: route.id, status: "completed")
        }

        // Auto-advance: load the next stop into this same screen so
        // the driver can tap Navigate immediately - no back-and-forth
        // to Dashboard and re-opening a stop required.
        if let next = others.filter({ $0.isPending }).sorted(by: { $0.order < $1.order }).first {
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
    // B2: "arrival" / "completion" while the camera is open.
    @State private var photoCaptureType: String?
    @State private var pickedPhoto: UIImage?
    /// Types photographed at this stop during this screen's life - the
    /// queue drops an entry once it uploads, so it can't answer that.
    @State private var photosTaken: Set<String> = []
    @State private var photoError: String?
    @ObservedObject private var photoQueue = PhotoProofQueue.shared
    // B7
    @State private var showVideoCapture = false
    @State private var isCompressingVideo = false
    /// Optional date/time stamp printed on proof photos. Per phone, on by default.
    @AppStorage("proof.stampDateTime") private var stampDateTime = true
    @State private var showSkipConfirm = false
    @State private var showReasonSheet = false
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
                                photoProofButtons
                            }
                            // Mark Completed is in the pinned bottom bar.
                        }

                        // Available at every stage before completion: a
                        // blocked driveway is found on arrival, but a
                        // cancelled job is found before setting off.
                        // Phase 4: behind a small "…" menu so a gloved
                        // thumb can't hit it instead of the main button.
                        if vm.jobStatus != .completed && !vm.stop.isCompleted && !vm.stop.isSkipped {
                            skipButton
                        }
                        completionErrorBanner

                        Spacer(minLength: 40)
                    }
                    .padding()
                    .readableContentWidth()
                }
                .safeAreaInset(edge: .bottom) { bottomActionBar }
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
                    Task { await requestComplete() }
                }
            )
        }
        // B2: one tap opens the camera; the shot goes straight into the
        // on-phone queue (see PhotoProofQueue) - no separate Upload step,
        // and no waiting for signal.
        .padFullScreenSheet(isPresented: Binding(
            get: { photoCaptureType != nil },
            set: { if !$0 { photoCaptureType = nil } }
        )) {
            ImagePicker(image: $pickedPhoto) { image in
                if let type = photoCaptureType { queuePhoto(image, type: type) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showReasonSheet) {
            ReasonSheet(vm: vm) {
                showReasonSheet = false
                Task { await vm.markCompleted() }
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
        // Mark Completed / Skip advance this same screen to the next
        // stop (vm.stop is replaced in place). The camera was only set
        // on appear, so the map stayed on the stop just finished and the
        // new stop's pin sat off-screen - the driver saw an empty map.
        .onChange(of: vm.stop.id) { _, _ in
            guard !nav.isNavigating else { return }
            withAnimation { navCamera = stopRegion() }
        }
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

            // B8: the customer's time window, if the owner set one.
            if let window = vm.stop.timeWindowText {
                Label("Arrive \(window)", systemImage: "clock.badge.checkmark")
                    .font(.subheadline.bold())
                    .foregroundColor(WRTheme.gold)
                    .padding(.vertical, 6)
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
                CleanMapWash()

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
                            .stroke(Color(red: 0xD9 / 255, green: 0x9A / 255, blue: 0x00 / 255),
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            // Light and clean like the customer tracking page.
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .environment(\.colorScheme, .light)
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
                // Phase 4: the Start Driving button itself now lives in
                // the pinned bottom bar (bottomActionBar) - big, and in
                // thumb reach.

                // Same "starting this stop" gesture, but directions come
                // from the driver's own nav app - Waze for its police /
                // construction / closure alerts, which no other app may
                // show. Our tracking keeps running in the background, so
                // the customer link and texts still work.
                if let coordinate = vm.stop.coordinate {
                    ExternalNavigationButtons(coordinate: coordinate) {
                        if DriverSession.shared.activeShift == nil {
                            _ = await DriverSession.shared.startShift()
                        }
                        await vm.startDriving()
                    }
                }

            case .enRoute:
                // Now that they're on the way, arriving is the primary
                // action. Navigation becomes a secondary control so a
                // driver who closed the map can pull directions back
                // without re-triggering the customer text.
                // Phase 4: "I've Arrived" is in the pinned bottom bar.

                if let coordinate = vm.stop.coordinate {
                    // Already en route: just hand off directions, no
                    // second "on my way" text.
                    ExternalNavigationButtons(coordinate: coordinate) { }

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

            if !vm.stop.isCompleted && !vm.stop.isSkipped {
                PredictionLine(stop: vm.stop)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let arrivedAt = vm.atPropertyStart {
                TimerPill(arrivedAt: arrivedAt)
                // Past the predicted time: offer the optional reason chips.
                // Tapping one saves it with the visit; ignoring them never
                // blocks Complete.
                TimelineView(.periodic(from: arrivedAt, by: 5)) { context in
                    if vm.isOverPrediction(at: context.date) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Running long? Tap a reason (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.white.opacity(0.8))
                            ReasonChips(selected: vm.reasonCode, otherText: $vm.reasonText) { code, text in
                                vm.chooseReason(code, text: text)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Complete is never blocked. A stop that is running well over its
    /// usual time and has no reason yet gets a one-tap optional sheet first.
    private func requestComplete() async {
        if vm.reasonCode == nil && vm.willFlagNow() {
            showReasonSheet = true
        } else {
            await vm.markCompleted()
        }
    }

    // MARK: PHOTO PROOF (optional - not required to complete, but
    // encouraged for dispute resolution / proof of work)
    //
    // B2: an Arrival + Completion pair. The arrival photo is offered
    // only while arrived (it's the "before"); the completion photo while
    // arrived or completed. Neither ever blocks completing the stop.
    @ViewBuilder
    private var photoProofButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if vm.jobStatus == .arrived || photosTaken.contains("arrival") {
                    photoButton(type: "arrival", title: "Arrival Photo")
                        .disabled(vm.jobStatus != .arrived)
                }
                photoButton(type: "completion", title: "Completion Photo")
            }
            // B7: optional 15-second clip.
            Button {
                photoError = nil
                showVideoCapture = true
            } label: {
                HStack(spacing: 6) {
                    if isCompressingVideo { ProgressView().tint(WRTheme.gold) }
                    Image(systemName: photosTaken.contains("video") ? "checkmark.circle.fill" : "video.fill")
                    Text(isCompressingVideo ? "Preparing video…" : (photosTaken.contains("video") ? "Video Proof ✓" : "Video Proof (15 s)"))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(photosTaken.contains("video") ? WRTheme.gold : .white)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.black.opacity(0.25))
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color("WRThemeGold").opacity(0.6), lineWidth: 1))
            }
            .disabled(isCompressingVideo)
            .padFullScreenSheet(isPresented: $showVideoCapture) {
                VideoPicker { url in queueVideo(url) }
                    .ignoresSafeArea()
            }
            Toggle(isOn: $stampDateTime) {
                Label("Print date & time on photos", systemImage: "calendar.badge.clock")
                    .font(.caption)
            }
            .tint(WRTheme.gold)
            let waiting = photoQueue.pendingCount(stopId: vm.stop.id)
            if waiting > 0 {
                Label("\(waiting) photo\(waiting == 1 ? "" : "s") saved on this phone - uploading when there's signal.",
                      systemImage: "icloud.and.arrow.up")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let photoError {
                Text(photoError).font(.caption).foregroundColor(.red)
            }
        }
    }

    private func photoButton(type: String, title: String) -> some View {
        let taken = photosTaken.contains(type)
        return Button {
            photoError = nil
            photoCaptureType = type
        } label: {
            HStack(spacing: 6) {
                Image(systemName: taken ? "checkmark.circle.fill" : "camera.fill")
                Text(taken ? "\(title) ✓" : title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(taken ? WRTheme.gold : .white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.black.opacity(0.25))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color("WRThemeGold"), lineWidth: 1)
            )
        }
        .accessibilityLabel(taken ? "\(title) taken. Tap to take another." : "Take \(title)")
    }

    /// B7: shrink (<= 12 MB, 15 s, sound removed), then queue like a photo.
    private func queueVideo(_ raw: URL) {
        guard let companyId = CompanySession.shared.currentCompanyId,
              let routeId = vm.route?.id,
              let driverId = session.driver?.id else {
            photoError = "Couldn't save the video - you're not signed in to a route."
            return
        }
        let captured = Date()
        let loc = LocationService.shared
        let lat = loc.currentLocation?.latitude, lon = loc.currentLocation?.longitude
        let fixAge = loc.lastLocationUpdate.map { max(0, Int(captured.timeIntervalSince($0))) }
        let stopId = vm.stop.id, visitId = vm.stop.openVisitId
        isCompressingVideo = true
        Task {
            defer { try? FileManager.default.removeItem(at: raw) }
            do {
                let result = try await VideoProofCompressor.compress(raw)
                try await MainActor.run {
                    try photoQueue.enqueueVideo(file: result.url, bytes: result.bytes, companyId: companyId,
                                                routeId: routeId, stopId: stopId, driverId: driverId,
                                                visitId: visitId, latitude: lat, longitude: lon,
                                                gpsFixAgeSeconds: fixAge, capturedAt: captured)
                    photosTaken.insert("video")
                }
            } catch {
                await MainActor.run { photoError = error.localizedDescription }
            }
            await MainActor.run { isCompressingVideo = false }
        }
    }

    /// Saves to the on-phone queue with the capture time, the phone's
    /// GPS fix right now, and this visit's id. Never waits on network.
    private func queuePhoto(_ image: UIImage, type: String) {
        guard let companyId = CompanySession.shared.currentCompanyId,
              let routeId = vm.route?.id,
              let driverId = session.driver?.id else {
            photoError = "Couldn't save the photo - you're not signed in to a route."
            return
        }
        let loc = LocationService.shared
        let fixAge = loc.lastLocationUpdate.map { max(0, Int(Date().timeIntervalSince($0))) }
        let captured = Date()
        let tz = TimeZone(identifier: CompanySession.shared.currentCompany?.timeZoneIdentifier ?? "America/Toronto") ?? .current
        let finalImage = stampDateTime
            ? ProofPhotoStamp.apply(image, date: captured, address: vm.stop.address, timeZone: tz)
            : image
        do {
            try photoQueue.enqueue(
                image: finalImage, companyId: companyId, routeId: routeId, stopId: vm.stop.id,
                driverId: driverId, type: type, visitId: vm.stop.openVisitId,
                latitude: loc.currentLocation?.latitude, longitude: loc.currentLocation?.longitude,
                gpsFixAgeSeconds: fixAge,
                source: UIImagePickerController.isSourceTypeAvailable(.camera) ? "camera" : "library",
                capturedAt: captured)
            photosTaken.insert(type)
        } catch {
            photoError = "Couldn't save the photo: \(error.localizedDescription)"
        }
        photoCaptureType = nil
    }

    // MARK: BOTTOM ACTION BAR (Phase 4, glove-friendly)
    //
    // ONE big button, pinned to the bottom of the screen where a thumb
    // already is, that always shows the next step: Start Driving ->
    // I've Arrived -> Mark Completed. At least 72pt tall with large type,
    // so it works with gloves on and at a glance in the dark. Everything
    // else on the screen is secondary.
    @ViewBuilder
    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            SavedOnPhoneBadge()
            bottomActionButton
        }
    }

    @ViewBuilder
    private var bottomActionButton: some View {
        if let action = nextAction {
            Button {
                Task { await action.run() }
            } label: {
                HStack(spacing: 12) {
                    if vm.isCompleting {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: action.symbol)
                    }
                    Text(action.title)
                }
                .font(.title2.bold())
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(Color("WRThemeGold"), in: RoundedRectangle(cornerRadius: 18))
            }
            .disabled(!action.enabled)
            .opacity(action.enabled ? 1 : 0.5)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .readableContentWidth()
            .background(Color("WRBlack").opacity(0.95).ignoresSafeArea(edges: .bottom))
            .accessibilityHint("Next step for this stop")
        }
    }

    private struct NextAction {
        let title: String
        let symbol: String
        let enabled: Bool
        let run: () async -> Void
    }

    private var nextAction: NextAction? {
        guard !vm.stop.isSkipped else { return nil }
        switch vm.jobStatus {
        case .scheduled:
            // ONE tap: clock in if needed, mark en route (texts the
            // customer), and open in-app navigation.
            return NextAction(title: "Start Driving", symbol: "car.fill", enabled: true) {
                if DriverSession.shared.activeShift == nil {
                    _ = await DriverSession.shared.startShift()
                }
                await vm.startDriving()
                if let coordinate = vm.stop.coordinate {
                    await MainActor.run { nav.start(to: coordinate) }
                }
            }
        case .enRoute:
            // Not while a completion is still saving (see markArrived).
            return NextAction(title: "I've Arrived", symbol: "mappin.circle.fill",
                              enabled: vm.canMarkArrived) {
                await vm.markArrived()
            }
        case .arrived:
            return NextAction(title: "Mark Completed", symbol: "checkmark.circle.fill",
                              enabled: !vm.isCompleting && !vm.stop.isCompleted) {
                await requestComplete()
            }
        case .completed:
            return nil
        }
    }

    // MARK: SKIP (behind a small menu - Phase 4)
    private var skipButton: some View {
        HStack {
            Spacer()
            Menu {
                Button(role: .destructive) {
                    showSkipConfirm = true
                } label: {
                    Label("Skip Stop", systemImage: "forward.end.fill")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(vm.isCompleting)
        }
        .padding(.top, 6)
        .confirmationDialog(
            "Skip this stop?",
            isPresented: $showSkipConfirm,
            titleVisibility: .visible
        ) {
            Button("Skip Stop", role: .destructive) {
                Task { await vm.markSkipped() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The customer won't get a completion text and their tracking link will close.")
        }
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

// MARK: - Navigate with Waze / Google Maps / Apple Maps
//
// Free hand-off to the driver's own navigation app. Waze is the only way
// a driver gets police, construction and road-closure alerts - Waze does
// not let any other app display them. Universal https links: each opens
// the installed app straight into turn-by-turn, or the website if the app
// isn't installed, so no Info.plist URL-scheme entries are needed.
// `beforeOpen` runs first (e.g. clock in + mark the stop en route), so the
// customer's link and texts are live before the driver leaves this screen.
struct ExternalNavigationButtons: View {
    let coordinate: CLLocationCoordinate2D
    var beforeOpen: () async -> Void

    @Environment(\.openURL) private var openURL

    private var lat: String { String(format: "%.6f", coordinate.latitude) }
    private var lng: String { String(format: "%.6f", coordinate.longitude) }

    var body: some View {
        HStack(spacing: 10) {
            navButton("Waze", "https://waze.com/ul?ll=\(lat),\(lng)&navigate=yes")
            navButton("Google Maps", "https://www.google.com/maps/dir/?api=1&destination=\(lat),\(lng)&travelmode=driving")
            navButton("Apple Maps", "https://maps.apple.com/?daddr=\(lat),\(lng)&dirflg=d")
        }
    }

    private func navButton(_ title: String, _ link: String) -> some View {
        Button {
            Task {
                await beforeOpen()
                if let url = URL(string: link) { openURL(url) }
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.12))
                .cornerRadius(12)
        }
        .accessibilityLabel("Navigate with \(title)")
    }
}

