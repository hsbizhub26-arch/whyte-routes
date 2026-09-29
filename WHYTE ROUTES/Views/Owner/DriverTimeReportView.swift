import SwiftUI

// Answers "are they milking hours or getting the job done" - built
// from timestamps already captured by the En Route/Arrived/Complete
// buttons (DriverStopViewModel), no new driver-side action needed.
// Per stop: travel time is enRouteAt -> arrivedAt, service time is
// arrivedAt -> completedAt. Per shift: total duration minus every
// stop's travel+service time = unaccounted time (breaks, gas,
// washroom, or just slow) - not broken down further since none of
// that is tracked individually, and shouldn't be guessed at.
//
// Stops are matched to a shift by whether their arrivedAt falls
// inside that shift's start/end window, not by a stored shiftId
// (none exists) - reasonable for one active route per driver per day,
// which is how this app is actually used today.
struct DriverTimeReportView: View {

    let driver: Driver

    @EnvironmentObject private var auth: AuthSession

    @State private var shifts: [Shift] = []
    @State private var stops: [Stop] = []
    @State private var isLoading = true
    @State private var hasLoadedStopsOnce = false

    /// Only owners and managers may delete time records. A driver never
    /// reaches this screen, but gating the action (in addition to the
    /// Firestore rule, which refuses a driver's delete server-side)
    /// keeps the capability explicit.
    private var canDelete: Bool { auth.role == .owner || auth.role == .manager }

    private let shiftRepo = ShiftRepository()
    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shifts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No shifts recorded yet.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(shifts) { shift in
                        Section {
                            shiftSummary(shift)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if canDelete {
                                        Button(role: .destructive) {
                                            delete(shift)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            ForEach(stopsDuring(shift)) { stop in
                                stopRow(stop)
                            }
                        } header: {
                            Text(Self.dateFormatter.string(from: shift.startedAt))
                        } footer: {
                            if let unaccounted = unaccountedTime(shift) {
                                Text("Unaccounted time: \(Self.durationString(unaccounted)) - breaks, gas, washroom, travel between stops not individually tracked.")
                            }
                        }
                    }
                }
                .readableListWidth()
            }
        }
        .navigationTitle("\(driver.name) - Time")
        .onAppear(perform: load)
    }

    private func delete(_ shift: Shift) {
        // Optimistic: drop it from the list immediately, restore if the
        // server refuses (e.g. a manager whose role changed underneath
        // them). The Firestore rule is the real gate.
        let previous = shifts
        shifts.removeAll { $0.id == shift.id }
        Task {
            do {
                try await shiftRepo.deleteShift(driverId: driver.id, shiftId: shift.id)
            } catch {
                await MainActor.run { shifts = previous }
                safePrint("⚠️ Failed to delete shift \(shift.id): \(error.localizedDescription)")
            }
        }
    }

    private func load() {
        Task {
            let fetchedShifts = await shiftRepo.fetchRecentShifts(driverId: driver.id)
            await MainActor.run {
                shifts = fetchedShifts
                isLoading = false
            }
        }

        routeRepo.fetchRouteForDriver(driverId: driver.id) { route in
            guard let route else { return }
            stopsRepo.loadStops(forRoute: route.id) { fetched in
                Task { @MainActor in
                    guard !hasLoadedStopsOnce else { return }
                    hasLoadedStopsOnce = true
                    stops = fetched
                }
            }
        }
    }

    private func stopsDuring(_ shift: Shift) -> [Stop] {
        let end = shift.endedAt ?? Date()
        return stops
            .filter { stop in
                guard let arrived = stop.arrivedAt else { return false }
                return arrived >= shift.startedAt && arrived <= end
            }
            .sorted { ($0.arrivedAt ?? .distantPast) < ($1.arrivedAt ?? .distantPast) }
    }

    private func travelTime(_ stop: Stop) -> TimeInterval? {
        guard let enRoute = stop.enRouteAt, let arrived = stop.arrivedAt else { return nil }
        return arrived.timeIntervalSince(enRoute)
    }

    private func serviceTime(_ stop: Stop) -> TimeInterval? {
        guard let arrived = stop.arrivedAt, let completed = stop.completedAt else { return nil }
        return completed.timeIntervalSince(arrived)
    }

    private func unaccountedTime(_ shift: Shift) -> TimeInterval? {
        guard let end = shift.endedAt else { return nil }
        let shiftDuration = end.timeIntervalSince(shift.startedAt)
        let accounted = stopsDuring(shift).reduce(0.0) { total, stop in
            total + (travelTime(stop) ?? 0) + (serviceTime(stop) ?? 0)
        }
        return max(0, shiftDuration - accounted)
    }

    @ViewBuilder
    private func shiftSummary(_ shift: Shift) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shift")
                    .font(.headline)
                Text("\(Self.timeFormatter.string(from: shift.startedAt)) - \(shift.endedAt.map { Self.timeFormatter.string(from: $0) } ?? "In progress")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(Self.durationString((shift.endedAt ?? Date()).timeIntervalSince(shift.startedAt)))
                .font(.headline)
                .foregroundColor(WRTheme.gold)
        }
    }

    private func stopRow(_ stop: Stop) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(stop.customerName ?? "Stop")
                    .font(.subheadline.bold())
                HStack(spacing: 14) {
                    if let travel = travelTime(stop) {
                        Label(Self.durationString(travel), systemImage: "car.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let service = serviceTime(stop) {
                        Label(Self.durationString(service), systemImage: "wrench.and.screwdriver.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval)) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
