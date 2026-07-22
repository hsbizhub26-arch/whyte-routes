import SwiftUI

// Supersedes the old AssignRouteView (assign-only, no editing). Real
// dispatching needs more than a one-time assignment: reordering stops
// as conditions change (e.g. re-prioritizing by which area got hit
// hardest), adding/removing stops mid-route, and reassigning the
// whole route to a different driver/crew when workload needs
// rebalancing. All three are handled here in one screen.
struct EditRouteView: View {

    let routeId: String

    @Environment(\.dismiss) private var dismiss

    @State private var routeName = ""
    @State private var stops: [Stop] = []
    @State private var drivers: [Driver] = []
    @State private var selectedDriverId: String?

    @State private var originalStopIds: Set<String> = []
    @State private var originalDriverId: String?
    @State private var hasLoadedStopsOnce = false

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var historyStop: Stop?
    @State private var pickerTargetId: String?
    @State private var showUpgradePrompt = false
    @State private var moveTargetStop: Stop?
    @State private var otherRoutes: [Route] = []

    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()
    private let driverRepo = FirestoreDriverRepository()
    private let access = FeatureAccessManager.shared

    private var approximateDistanceKM: Double {
        RouteOptimizationService.totalDistanceKM(stops)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading route…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        Section("Route") {
                            TextField("Route name", text: $routeName)
                        }

                        Section("Driver") {
                            Picker("Assign to", selection: $selectedDriverId) {
                                Text("Unassigned").tag(String?.none)
                                ForEach(drivers) { driver in
                                    Text(driver.name).tag(String?.some(driver.id))
                                }
                            }
                        }

                        Section {
                            ForEach(stops) { stop in
                                stopRow(stop)
                            }
                            .onDelete { stops.remove(atOffsets: $0) }
                            .onMove { stops.move(fromOffsets: $0, toOffset: $1) }

                            Button {
                                let newStop = Stop(address: "")
                                stops.append(newStop)
                                pickerTargetId = newStop.id
                            } label: {
                                Label("Add Stop", systemImage: "plus.circle")
                            }

                            if stops.count > 2 {
                                Button {
                                    if access.canAccessAdvancedDispatch() {
                                        stops = RouteOptimizationService.optimize(stops)
                                    } else {
                                        showUpgradePrompt = true
                                    }
                                } label: {
                                    Label("Optimize Route", systemImage: "wand.and.stars")
                                }
                            }
                        } header: {
                            Text("Stops")
                        } footer: {
                            if approximateDistanceKM > 0 {
                                Text("Drag to reorder - the driver sees stops in this order. Approx. \(approximateDistanceKM, specifier: "%.1f") km straight-line (not actual driving distance).")
                            } else {
                                Text("Drag to reorder - the driver sees stops in this order.")
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Edit Route")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(isSaving || routeName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
            }
            .onAppear(perform: loadEverything)
            .sheet(item: $historyStop) { stop in
                NotificationHistoryView(routeId: routeId, stop: stop)
            }
            .sheet(isPresented: Binding(
                get: { pickerTargetId != nil },
                set: { if !$0 { pickerTargetId = nil } }
            )) {
                CustomerPickerView { customer in
                    apply(customer, toStopId: pickerTargetId)
                }
            }
            .sheet(isPresented: $showUpgradePrompt) {
                UpgradeRequiredView(featureName: "Route Optimization", requiredTier: .premiumPlus)
            }
            .sheet(item: $moveTargetStop) { stop in
                moveStopSheet(stop)
            }
        }
    }

    @ViewBuilder
    private func moveStopSheet(_ stop: Stop) -> some View {
        NavigationStack {
            Group {
                if otherRoutes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No other active routes to move this to.")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(otherRoutes) { route in
                        Button {
                            moveStop(stop, to: route)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.name)
                                    .foregroundColor(.primary)
                                Text(drivers.first { $0.id == route.driverId }?.name ?? "Unassigned")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move \(stop.customerName ?? "Stop")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { moveTargetStop = nil }
                }
            }
        }
    }

    // Row action buttons are given explicit vertical padding (not just
    // their text glyphs) so each has a real tap target - the previous
    // plain-text buttons packed a driver-hand-unfriendly, sub-44pt
    // target into a Form row and were easy to mis-tap on a real phone.
    private func rowActionButton(_ title: String, color: Color = .yellow, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(color)
                .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func stopRow(_ stop: Stop) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if stop.customerId != nil {
                Text(stop.customerName ?? "Customer")
                    .font(.headline)
                Text(stop.address)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let phone = stop.customerPhone, !phone.isEmpty {
                    Text(phone)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                rowActionButton("Change Customer") {
                    pickerTargetId = stop.id
                }
            } else {
                // Legacy stop, created before customer linking existed -
                // still works via its own cached fields (see
                // NotificationService), but offer an easy upgrade path.
                if let name = stop.customerName, !name.isEmpty {
                    Text(name).font(.headline)
                    Text(stop.address).font(.caption).foregroundColor(.secondary)
                }
                rowActionButton(stop.customerName?.isEmpty == false ? "Link to a Customer Record" : "Select Customer") {
                    pickerTargetId = stop.id
                }
            }

            if originalStopIds.contains(stop.id) {
                rowActionButton("View Notification Log") {
                    historyStop = stop
                }

                // Live, immediate overrides - not staged into the Save
                // button below, which batches a local snapshot taken
                // when this screen opened and would risk overwriting
                // whatever a driver has done since. These write
                // straight to Firestore the moment they're tapped:
                // - a driver marked something complete that wasn't
                //   theirs to finish (undo it)
                // - the owner/manager did a stop themselves while
                //   driving by (mark it done directly)
                // - one driver finished early and can take over a stop
                //   still sitting on someone else's route (move it)
                HStack(spacing: 28) {
                    rowActionButton(
                        stop.isCompleted ? "Mark Incomplete" : "Mark Complete",
                        color: stop.isCompleted ? .orange : .green
                    ) {
                        toggleCompletion(stop)
                    }

                    rowActionButton("Move to Another Route") {
                        moveTargetStop = stop
                        loadOtherRoutes()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func toggleCompletion(_ stop: Stop) {
        var updated = stop
        if updated.isCompleted {
            // Full reset back to untouched - not just flipping the
            // flag, since a half-reset (isCompleted false but status
            // still "completed") would be an inconsistent state for
            // everything else that reads Stop.status.
            updated.isCompleted = false
            updated.status = JobStatus.scheduled.rawValue
            updated.enRouteAt = nil
            updated.arrivedAt = nil
            updated.completedAt = nil
        } else {
            updated.isCompleted = true
            updated.status = JobStatus.completed.rawValue
            updated.completedAt = Date()
        }

        stopsRepo.updateStop(routeId: routeId, stop: updated) { success in
            Task { @MainActor in
                guard success else {
                    errorMessage = "Couldn't update that stop - check your connection."
                    return
                }
                if let index = stops.firstIndex(where: { $0.id == stop.id }) {
                    stops[index] = updated
                }
                // Keep the route's own completed status honest - same
                // reasoning as the full-workday audit fix in
                // DriverStopViewModel: a stale "completed" route can
                // shadow a real one on a driver's next fetch.
                let others = stops.filter { $0.id != stop.id }
                let allDone = updated.isCompleted && others.allSatisfy { $0.isCompleted }
                routeRepo.updateStatus(routeId: routeId, status: allDone ? "completed" : "assigned")
            }
        }
    }

    private func loadOtherRoutes() {
        routeRepo.fetchRoutes { fetched in
            Task { @MainActor in
                otherRoutes = fetched.filter { $0.id != routeId && $0.status != "completed" }
            }
        }
    }

    private func moveStop(_ stop: Stop, to targetRoute: Route) {
        stopsRepo.moveStop(stop, fromRouteId: routeId, toRouteId: targetRoute.id, newDriverId: targetRoute.driverId) { success in
            Task { @MainActor in
                if success {
                    stops.removeAll { $0.id == stop.id }
                    originalStopIds.remove(stop.id)
                    moveTargetStop = nil
                } else {
                    errorMessage = "Couldn't move that stop - check your connection."
                }
            }
        }
    }

    private func apply(_ customer: Customer, toStopId id: String?) {
        guard let id, let index = stops.firstIndex(where: { $0.id == id }) else { return }
        stops[index].customerId = customer.id
        stops[index].customerName = customer.name
        stops[index].customerPhone = customer.phone
        stops[index].customerEmail = customer.email
        stops[index].customerOptedIn = customer.notificationsOptIn
        stops[index].address = customer.address
        stops[index].latitude = customer.latitude
        stops[index].longitude = customer.longitude
    }

    private func loadEverything() {
        routeRepo.fetchRoute(routeId: routeId) { route in
            Task { @MainActor in
                if let route {
                    routeName = route.name
                    selectedDriverId = (route.driverId?.isEmpty == false) ? route.driverId : nil
                    originalDriverId = selectedDriverId
                }
            }
        }

        stopsRepo.loadStops(forRoute: routeId) { fetched in
            Task { @MainActor in
                // loadStops is a live listener; only take the first
                // delivery here so a driver's in-progress GPS/stop
                // updates elsewhere don't reshuffle the form out from
                // under the owner while they're mid-edit.
                guard !hasLoadedStopsOnce else { return }
                hasLoadedStopsOnce = true
                stops = fetched.sorted { $0.order < $1.order }
                originalStopIds = Set(fetched.map { $0.id })
                isLoading = false
            }
        }

        driverRepo.fetchDrivers { result in
            Task { @MainActor in
                if case .success(let fetched) = result {
                    drivers = fetched
                }
            }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        routeRepo.updateRoute(routeId: routeId, name: routeName, driverId: selectedDriverId) { success in
            Task { @MainActor in
                guard success else {
                    isSaving = false
                    errorMessage = "Couldn't save the route - check your connection and try again."
                    return
                }

                if originalDriverId != selectedDriverId {
                    if let originalDriverId, !originalDriverId.isEmpty {
                        driverRepo.clearActiveRoute(driverId: originalDriverId)
                    }
                    if let selectedDriverId {
                        driverRepo.assignRoute(driverId: selectedDriverId, routeId: routeId)
                    }
                }

                let orderedStops = stops.enumerated().map { index, stop -> Stop in
                    var updated = stop
                    updated.order = index
                    updated.driverId = selectedDriverId
                    return updated
                }
                stopsRepo.saveStops(forRoute: routeId, stops: orderedStops)

                let currentIds = Set(orderedStops.map { $0.id })
                for removedId in originalStopIds.subtracting(currentIds) {
                    stopsRepo.deleteStop(routeId: routeId, stopId: removedId)
                }

                isSaving = false
                dismiss()
            }
        }
    }
}
