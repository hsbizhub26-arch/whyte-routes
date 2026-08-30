import Foundation
import Combine
import CoreLocation
import FirebaseAuth

@MainActor
final class DriverSession: ObservableObject {

    static let shared = DriverSession()
    private init() {}

    @Published var driver: Driver?
    @Published var assignedRoute: Route?
    @Published var activeStops: [Stop] = []
    @Published var activeShift: Shift?
    @Published var shiftError: String?
    /// Set when the route genuinely couldn't be read. Distinct from
    /// "no stops" - see loadStops.
    @Published var stopsError: String?
    /// False until a stops read has actually SUCCEEDED once. An empty
    /// activeStops means "route finished" only if this is true;
    /// otherwise it just means nothing has come back yet.
    @Published var hasLoadedStops = false

    /// Bounded first-load retries for permission-denied only. See
    /// loadStops - this covers the window where a just-created
    /// users/{uid} is not yet visible to the rules engine. Reset on
    /// every successful load and on logout, so it can never leak into
    /// a later genuine denial.
    private var permissionRetries = 0
    private static let maxPermissionRetries = 3

    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()
    private let shiftRepo = ShiftRepository()

    // MARK: Load driver after login
    func setDriver(_ driver: Driver) {
        self.driver = driver
        loadAssignedRoute()
        Task { await restoreActiveShift() }
    }

    // MARK: Refresh current driver's route/stops (called when the tab view appears)
    func refresh() {
        loadAssignedRoute()
    }

    // MARK: Log out (clears local driver session state)
    func logout() {
        driver = nil
        assignedRoute = nil
        activeStops = []
        activeShift = nil
        stopsError = nil
        hasLoadedStops = false
        permissionRetries = 0
    }

    // MARK: - Shift start/end
    // Restores an already-active shift (e.g. app was killed mid-shift)
    // so Start Shift doesn't silently open a second, orphaned shift -
    // and resumes GPS tracking, since it doesn't survive a relaunch on
    // its own (CLLocationManager isn't restarted automatically here).
    private func restoreActiveShift() async {
        guard let driverId = driver?.id else { return }
        activeShift = await shiftRepo.fetchActiveShift(driverId: driverId)
        if activeShift != nil {
            LocationService.shared.startTracking(driverId: driverId)
            TrackingBroadcastService.shared.start()
        }
    }

    @discardableResult
    func startShift() async -> Bool {
        shiftError = nil
        guard let driverId = driver?.id else {
            shiftError = "No driver profile loaded yet - try signing out and back in."
            return false
        }
        guard activeShift == nil else { return false }
        do {
            activeShift = try await shiftRepo.startShift(driverId: driverId)
            LocationService.shared.startTracking(driverId: driverId)
            TrackingBroadcastService.shared.start()

            // Tell this route's customers the crew is out, and hand
            // each of them their tracking link. Deliberately detached:
            // Start Shift returns the moment the shift exists, because
            // a driver tapping it is already pulling away and must not
            // wait on a few dozen sequential SMS sends - nor see them
            // fail. Tracking has started above, so by the time the
            // first text lands the link it carries is already live.
            if let routeId = assignedRoute?.id {
                Task.detached {
                    await NotificationService.shared.notifyShiftStart(routeId: routeId)
                }
            }
            return true
        } catch {
            shiftError = error.localizedDescription
            print("⚠️ DriverSession.startShift failed: \(error)")
            return false
        }
    }

    @discardableResult
    func endShift() async -> Bool {
        shiftError = nil
        guard let driverId = driver?.id, let shift = activeShift else { return false }
        do {
            try await shiftRepo.endShift(driverId: driverId, shiftId: shift.id)
            activeShift = nil
            LocationService.shared.stopTracking()
            TrackingBroadcastService.shared.stop()
            return true
        } catch {
            shiftError = error.localizedDescription
            print("⚠️ DriverSession.endShift failed: \(error)")
            return false
        }
    }

    // MARK: Load assigned route
    func loadAssignedRoute() {
        guard let id = driver?.id else { return }

        routeRepo.fetchRouteForDriver(driverId: id) { route in
            Task { @MainActor in
                self.assignedRoute = route
                if let route = route {
                    self.loadStops(routeId: route.id)
                }
            }
        }
    }

    // MARK: Load a specific route by id (used to restore an active route on relaunch)
    func loadAssignedRoute(routeId: String) async {
        guard let id = driver?.id else { return }
        routeRepo.fetchRouteForDriver(driverId: id) { route in
            Task { @MainActor in
                self.assignedRoute = route
                if let route = route {
                    self.loadStops(routeId: route.id)
                }
            }
        }
    }

    // MARK: Load stops
    func loadStops(routeId: String) {
        guard let uid = Auth.auth().currentUser?.uid else {
            stopsError = "You're signed out. Sign in again to load your route."
            return
        }

        stopsRepo.loadStops(forRoute: routeId, assignedTo: uid) { result in
            Task { @MainActor in
                switch result {
                case .success(let stops):
                    self.permissionRetries = 0
                    self.stopsError = nil
                    self.hasLoadedStops = true
                    self.activeStops = stops
                    TrackingBroadcastService.shared.refreshLinks()

                case .failure(let error):
                    // A just-invited driver can reach this before the
                    // rules engine can see their users/{uid} document -
                    // UserPermissionsService waits for that, and this is
                    // the belt to its braces. Retry ONLY on
                    // permission-denied, only a few times, and only
                    // before anything has ever loaded: a denial after a
                    // successful load is a real one and must surface.
                    let isPermissionDenied = (error as? StopsRepository.StopsError) == .permissionDenied

                    if isPermissionDenied,
                       self.permissionRetries < Self.maxPermissionRetries,
                       !self.hasLoadedStops {
                        self.permissionRetries += 1
                        let attempt = self.permissionRetries
                        print("⚠️ stops denied on first load - retry \(attempt)/\(Self.maxPermissionRetries)")
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64(400_000_000) * UInt64(attempt))
                            self.loadStops(routeId: routeId)
                        }
                        return
                    }

                    // activeStops is deliberately left ALONE. Blanking
                    // it on a failed read is what turned a permission
                    // error into "Route Completed 🎉" - a driver being
                    // told their morning was done before it started.
                    // A driver mid-route who loses signal keeps the
                    // stops they already have, and gets a banner.
                    self.stopsError = isPermissionDenied
                        ? "Couldn't load your route. Pull down to retry, or sign out and back in."
                        : "Couldn't load your route. \(error.localizedDescription)"
                    print("⚠️ DriverSession.loadStops failed: \(error)")
                }
            }
        }
    }

    // MARK: Mark stop complete
    func completeStop(_ stop: Stop) {
        guard let routeId = assignedRoute?.id else { return }

        var updatedStops = activeStops
        if let index = updatedStops.firstIndex(where: { $0.id == stop.id }) {
            updatedStops[index].isCompleted = true
        }

        activeStops = updatedStops
        stopsRepo.saveStops(forRoute: routeId, stops: updatedStops)
        // Finishing one stop moves everyone behind it up the queue.
        TrackingBroadcastService.shared.refreshLinks()
    }

    // MARK: Next stop
    var nextStop: Stop? {
        activeStops.first { !$0.isCompleted }
    }
}

