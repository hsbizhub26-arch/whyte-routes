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

    init(stop: Stop) {
        self.stop = stop
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
            LocationService.shared.setArrivalTarget(lat: next.latitude, lng: next.longitude)
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

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile

        Task {
            do {
                let eta = try await MKDirections(request: request).calculateETA()
                await MainActor.run {
                    self.etaMinutes = Int(eta.expectedTravelTime / 60)
                }
            } catch {
                await MainActor.run { self.etaMinutes = nil }
            }
        }
    }
}

struct DriverStopView: View {

    @StateObject private var vm: DriverStopViewModel
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
                        completeButton

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
            LocationService.shared.setArrivalTarget(lat: vm.stop.latitude, lng: vm.stop.longitude)
            vm.loadETA()
            // Keep the screen awake while an active stop is open - a
            // mounted tablet/phone dimming mid-shift is exactly the
            // kind of friction this feature is meant to remove.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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
            Map(coordinateRegion: .constant(
                MKCoordinateRegion(
                    center: coordinate,
                    span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            ))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color("WRThemeGold"), lineWidth: 2)
            )
        }
    }

    // MARK: ACTION BUTTONS
    private var actionButtons: some View {
        VStack(spacing: 16) {
            NavigationButton(coordinate: vm.stop.coordinate)
            TimerPill()
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
