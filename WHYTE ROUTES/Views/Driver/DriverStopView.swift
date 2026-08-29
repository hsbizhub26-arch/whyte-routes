import SwiftUI
import MapKit
import Combine

@MainActor
final class DriverStopViewModel: ObservableObject {

    @Published var stop: Stop
    @Published var isCompleting = false
    @Published var routeCompleted = false
    @Published var etaMinutes: Int?

    private let routeService = RouteService.shared
    private let session = DriverSession.shared

    // GPS older than this is treated as unusable for an ETA
    // notification - better to send nothing than tell a customer
    // "10 minutes away" based on where the driver was half an hour
    // ago. Threshold flags are local-only "don't bother calling
    // again this session" hints; the real once-only guarantee is
    // sendCustomerNotification's server-side idempotency check, so a
    // second device or a relaunch can never cause a duplicate.
    private static let maxLocationAge: TimeInterval = 5 * 60
    private var eta15Notified = false
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
            Task { @MainActor in
                guard let self, self.jobStatus == .enRoute else {
                    self?.stopETARefreshTimer()
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
        routeService.updateStop(routeId: route.id, stop: stop)
        await NotificationService.shared.notify(stop: stop, routeId: route.id, status: .enRoute)
    }

    func markArrived() async {
        guard let route else { return }
        stop.status = JobStatus.arrived.rawValue
        stop.arrivedAt = Date()
        routeService.updateStop(routeId: route.id, stop: stop)
        await NotificationService.shared.notify(stop: stop, routeId: route.id, status: .arrived)
    }

    // MARK: - MARK STOP COMPLETED
    func markCompleted() async {
        guard let route else { return }

        isCompleting = true
        stop.isCompleted = true
        stop.status = JobStatus.completed.rawValue
        stop.completedAt = Date()

        routeService.updateStop(routeId: route.id, stop: stop)
        await NotificationService.shared.notify(stop: stop, routeId: route.id, status: .completed)

        // This customer's service is done, so their live tracking ends
        // here: the position document is deleted and the link marked
        // complete. Without this they could keep watching the truck
        // drive on to other people's homes for the rest of the shift.
        TrackingLinkRepository().closeOut(stopId: stop.id)

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
        // this only gates the eta15/eta10 notification triggers below,
        // not the driver's own on-screen ETA display, which stays
        // useful even with slightly old location data.
        let locationIsFresh: Bool
        if let lastUpdate = LocationService.shared.lastLocationUpdate {
            locationIsFresh = Date().timeIntervalSince(lastUpdate) <= Self.maxLocationAge
        } else {
            locationIsFresh = false
        }

        let request = MKDirections.Request()
        let sourceItem = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        let destinationItem = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
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

    // Only meaningful while actually driving to this stop - once
    // arrived/completed, "how far away is the driver" no longer
    // applies. Threshold crossing only (>15 -> <=15), not "is
    // currently under 15", so a fluctuating ETA bouncing around 14-16
    // minutes doesn't matter once it's crossed once - see the
    // eta15Notified/eta10Notified guards.
    private func checkETAThresholds(_ minutes: Int) {
        guard jobStatus == .enRoute, let route else { return }

        if !eta10Notified, minutes <= 10 {
            eta10Notified = true
            eta15Notified = true // 10 implies 15 already happened/is moot
            Task { await NotificationService.shared.notify(stop: stop, routeId: route.id, type: "eta10") }
        } else if !eta15Notified, minutes <= 15 {
            eta15Notified = true
            Task { await NotificationService.shared.notify(stop: stop, routeId: route.id, type: "eta15") }
        }
    }
}

struct DriverStopView: View {

    @StateObject private var vm: DriverStopViewModel
    @StateObject private var nav = NavigationSession()
    @ObservedObject private var session = DriverSession.shared
    @ObservedObject private var access = FeatureAccessManager.shared
    @State private var showPhotoCapture = false
    @State private var proofPhotoURL: String?

    init(stop: Stop) {
        _vm = StateObject(wrappedValue: DriverStopViewModel(stop: stop))
    }

    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            if vm.routeCompleted {
                routeCompletedView
            } else {
                ScrollView {
                    VStack(spacing: 20) {

                        progressBar
                        header
                        mapSection
                        actionButtons
                        // smsButton intentionally hidden - the tracking link it
                        // sends has no real destination yet (no onOpenURL
                        // handler, no tracking page built). Re-enable once
                        // customer tracking (Phase 3) is actually wired up -
                        // see smsButton below, left in place for that.
                        statusControl
                        // photoProofButton intentionally hidden for the snow
                        // beta - a photo step adds real friction to exactly
                        // what overnight snow ops needs to be fast: gloves,
                        // darkness, snow falling, dozens of properties to
                        // clear before people wake up. Not tier-gating this
                        // away (access.canAccessProofOfWork() still governs
                        // whether it WOULD show), just not calling it -
                        // PhotoProofView/PhotoUploader/the Storage rules all
                        // stay intact for landscaping jobs, where before/after
                        // photos are genuinely useful and driver pace isn't
                        // the same constraint.
                        //
                        // One button per stage, Uber-Driver-style - only
                        // shown once actually arrived. It used to render
                        // (enabled) at every stage, including .scheduled -
                        // a driver could tap straight to Completed without
                        // ever tapping Start Driving or I've Arrived,
                        // silently skipping the en-route/arrived customer
                        // texts along with the steps themselves.
                        if vm.jobStatus == .arrived || vm.jobStatus == .completed {
                            completeButton
                        }

                        Spacer(minLength: 40)
                    }
                    .padding()
                }
            }
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
            Map(initialPosition: .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            )) {
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
        }
    }

    // Sits over the map while navigating: what the next turn is, how
    // far to it, and what's left overall. Deliberately large text -
    // this is read at a glance from a mount, in the dark, moving.
    private var maneuverBanner: some View {
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

    // MARK: ACTION BUTTONS
    private var actionButtons: some View {
        VStack(spacing: 16) {
            // IN-APP NAVIGATION IS THE ONLY NAVIGATION.
            //
            // There used to be a second "Navigate" button directly
            // underneath this one that handed off to Apple Maps /
            // Google Maps / Waze. Two buttons doing what looks like the
            // same job, and the external one was the one that read
            // simply "Navigate" - so that is the one drivers pressed,
            // and the app they ended up in was Apple Maps. The in-app
            // turn-by-turn engine was never what anyone actually saw.
            //
            // Leaving the route inside the app is the point: it keeps
            // the stop list, the arrival geofence, the customer's
            // tracking link and the shift timer all live, none of which
            // survive a bounce out to another app.
            if let coordinate = vm.stop.coordinate {
                Button {
                    if nav.isNavigating {
                        nav.stop()
                    } else {
                        nav.start(to: coordinate)
                    }
                } label: {
                    Label(
                        nav.isNavigating ? "End" : "GO",
                        systemImage: nav.isNavigating ? "xmark.circle.fill" : "location.north.circle.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(nav.isNavigating ? Color.red.opacity(0.85) : Color("WRThemeGold"))
                    .foregroundColor(nav.isNavigating ? .white : .black)
                    .cornerRadius(12)
                }
            }

            // Surfaced here rather than only in the maneuver banner:
            // without it, tapping GO with no GPS fix yet did nothing
            // visible at all, which reads as a dead button.
            if let error = nav.errorMessage, !nav.isNavigating {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let arrivedAt = vm.stop.arrivedAt {
                TimerPill(arrivedAt: arrivedAt)
            }
        }
    }

    // MARK: STATUS CONTROL (En Route / Arrived - each notifies the
    // customer via NotificationService; Completed is handled by the
    // existing completeButton below)
    @ViewBuilder
    private var statusControl: some View {
        switch vm.jobStatus {
        case .scheduled:
            Button {
                Task { await vm.startDriving() }
            } label: {
                Label("Start Driving", systemImage: "car.fill")
                    .font(.headline)
                    .foregroundColor(.black)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color("WRThemeGold"))
                    .cornerRadius(14)
            }

        case .enRoute:
            Button {
                Task { await vm.markArrived() }
            } label: {
                Label("I've Arrived", systemImage: "mappin.circle.fill")
                    .font(.headline)
                    .foregroundColor(.black)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color("WRThemeGold"))
                    .cornerRadius(14)
            }

        case .arrived, .completed:
            EmptyView()
        }
    }

    // MARK: SMS
    private var smsButton: some View {
        Group {
            if let phone = vm.stop.customerPhone {
                SMSButton(title: "Text Customer",
                          phone: phone,
                          link: "https://whyteroutes.app/tracking/\(vm.stop.id)")
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
                proofPhotoURL = nil
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

