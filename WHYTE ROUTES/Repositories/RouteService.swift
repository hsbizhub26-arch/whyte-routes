import Foundation
import Combine
import FirebaseFirestore

struct DriverReportSummary {
    var completedStops: Int
    var totalKM: Double
    var totalTimeMinutes: Int
}

@MainActor
final class RouteService: ObservableObject {

    // MARK: - Singleton
    static let shared = RouteService()
    private init() {}

    // MARK: - Published
    @Published private(set) var routes: [Route] = []
    @Published private(set) var stops: [Stop] = []

    // Route documents never carry their own stops (those live in a
    // subcollection - see StopsRepository), so Route.stops is always
    // empty when loaded via fetchRoutes/listenToRoutes. reportFor()
    // needs real stop data to count completions, so this cache is
    // populated separately per route once its stops are fetched.
    @Published private(set) var stopsByRoute: [String: [Stop]] = [:]

    // MARK: - Dependencies
    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()
    private let trackingRepo = TrackingLinkRepository()

    private var routeListener: ListenerRegistration?
    private var stopsListener: ListenerRegistration?

    // MARK: - Load All Routes (Live)
    func listenToRoutes() {
        routeRepo.listenToRoutes { [weak self] routes in
            Task { @MainActor in
                self?.routes = routes
            }
        }
    }

    // MARK: - Load Routes Once
    func loadRoutesOnce() {
        routeRepo.fetchRoutes { [weak self] routes in
            Task { @MainActor in
                self?.routes = routes
                self?.loadStopsForReports(routes)
            }
        }
    }

    // MARK: - Populate stopsByRoute (see its declaration for why this
    // is needed separately from Route.stops)
    private func loadStopsForReports(_ routes: [Route]) {
        for route in routes {
            stopsRepo.loadStops(forRoute: route.id) { [weak self] stops in
                Task { @MainActor in
                    self?.stopsByRoute[route.id] = stops
                }
            }
        }
    }

    // MARK: - Listen to Stops for a Route
    func listenToStops(for routeId: String) {
        stopsRepo.loadStops(forRoute: routeId) { [weak self] stops in
            Task { @MainActor in
                self?.stops = stops.sorted(by: { $0.order < $1.order })
            }
        }
    }

    // MARK: - Save Stop List (reordering, completion, etc.)
    func saveStops(for routeId: String, _ stops: [Stop]) {
        stopsRepo.saveStops(forRoute: routeId, stops: stops) { success in
            if !success {
                print("❌ RouteService: Failed to save stops")
            }
        }
    }

    // MARK: - Update a Single Stop
    func updateStop(routeId: String, stop: Stop) {
        stopsRepo.updateStop(routeId: routeId, stop: stop) { success in
            if !success {
                print("❌ Failed to update stop")
            }
        }
    }

    // MARK: - Assign Driver to Route
    func assignDriver(_ driverId: String, to routeId: String) {
        routeRepo.assignDriver(routeId: routeId, driverId: driverId)
    }

    // MARK: - Update Route Status
    func updateStatus(for routeId: String, status: String) {
        routeRepo.updateStatus(routeId: routeId, status: status)
    }

    // MARK: - Create New Route
    func createRoute(name: String,
                     driverId: String? = nil,
                     completion: @escaping (String?) -> Void) {
        routeRepo.createRoute(name: name, driverId: driverId, completion: completion)
    }

    // MARK: - Create Tracking Link for a Stop
    func createTrackingLink(routeId: String,
                            stop: Stop,
                            driverId: String,
                            completion: @escaping (TrackingLink?) -> Void) {

        trackingRepo.create(
            customerName: stop.customerName ?? "",
            address: stop.address,
            driverId: driverId,
            stopId: stop.id,
            // Binds the link to the person, not just the stop. Without
            // it the link can't be told apart from one belonging to a
            // customer this stop used to point at, and everything
            // downstream has to assume the worst and supersede it.
            customerId: stop.customerId,
            completion: completion
        )
    }

    // MARK: - Deactivate a Tracking Link
    func deactivateTrackingLink(_ linkId: String) {
        trackingRepo.deactivate(id: linkId)
    }

    // MARK: - Driver Report Summary
    func reportFor(_ driver: Driver) -> DriverReportSummary {
        let driverStops = routes
            .filter { $0.driverId == driver.id }
            .flatMap { stopsByRoute[$0.id] ?? [] }

        let completed = driverStops.filter { $0.isCompleted }.count

        return DriverReportSummary(
            completedStops: completed,
            totalKM: 0,
            totalTimeMinutes: 0
        )
    }

    // MARK: - Remove Listeners (important for performance)
    func stopListening() {
        routeListener?.remove()
        stopsListener?.remove()
        routeListener = nil
        stopsListener = nil
    }
}
