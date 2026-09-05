import SwiftUI
import CoreLocation
import FirebaseFunctions

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

    @State private var startAddress = ""
    @State private var startLatitude: Double?
    @State private var startLongitude: Double?
    @State private var endAddress = ""
    @State private var endLatitude: Double?
    @State private var endLongitude: Double?

    @State private var originalStopIds: Set<String> = []
    // Who each stop belonged to when this screen opened. Compared on
    // save so a stop re-pointed at a different customer can have the
    // previous customer's tracking links torn down - see save().
    @State private var originalStopCustomers: [String: String] = [:]
    @State private var originalDriverId: String?
    @State private var hasLoadedStopsOnce = false

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var historyStop: Stop?
    @State private var sendingLinkStopId: String?
    @State private var trackingLinkResults: [String: String] = [:]
    @State private var pickerTargetId: String?
    @State private var showUpgradePrompt = false
    // Which limit opened the upgrade sheet - it was hardcoded to
    // "Route Optimization", so hitting the stop cap advertised the
    // wrong feature.
    @State private var upgradeReason = "Route Optimization"
    @State private var moveTargetStop: Stop?
    @State private var otherRoutes: [Route] = []

    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()
    private let driverRepo = FirestoreDriverRepository()
    private let trackingRepo = TrackingLinkRepository()
    private let access = FeatureAccessManager.shared

    /// A stable stand-in for "which person is this stop", used only to
    /// notice that it changed. Falls back to the cached name and
    /// address for a one-off stop with no Customer record, the same
    /// way TrackingLink.belongsTo(_:) does.
    private func customerIdentity(of stop: Stop) -> String {
        if let customerId = stop.customerId { return "cid:\(customerId)" }
        return "adhoc:\(stop.customerName ?? "")|\(stop.address)"
    }

    private var startCoordinate: CLLocationCoordinate2D? {
        guard let startLatitude, let startLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: startLatitude, longitude: startLongitude)
    }

    private var endCoordinate: CLLocationCoordinate2D? {
        guard let endLatitude, let endLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude)
    }

    private var approximateDistanceKM: Double {
        RouteOptimizationService.totalDistanceKM(stops, startCoordinate: startCoordinate, endCoordinate: endCoordinate)
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
                                ForEach(DriverPickerOrdering.ordered(drivers)) { driver in
                                    Text(DriverPickerOrdering.label(for: driver)).tag(String?.some(driver.id))
                                }
                            }
                        }

                        Section {
                            HStack(spacing: 8) {
                                Circle().fill(.green).frame(width: 10, height: 10)
                                AddressAutocompleteField(address: $startAddress, placeholder: "Start location (optional)") { address, lat, lng in
                                    startAddress = address
                                    startLatitude = lat
                                    startLongitude = lng
                                }
                            }
                            HStack(spacing: 8) {
                                Circle().fill(.red).frame(width: 10, height: 10)
                                AddressAutocompleteField(address: $endAddress, placeholder: "End location (optional)") { address, lat, lng in
                                    endAddress = address
                                    endLatitude = lat
                                    endLongitude = lng
                                }
                            }
                        } header: {
                            Text("Route Endpoints")
                        } footer: {
                            Text("Leave blank to use the first/last stop as usual - set these to route from a fixed depot or back to the shop.")
                        }

                        Section {
                            ForEach(stops) { stop in
                                stopRow(stop)
                            }
                            .onDelete { stops.remove(atOffsets: $0) }
                            .onMove { stops.move(fromOffsets: $0, toOffset: $1) }

                            Button {
                                guard access.canAddStop(currentCount: stops.count) else {
                                    upgradeReason = "More Stops Per Route"
                                    showUpgradePrompt = true
                                    return
                                }
                                let newStop = Stop(address: "")
                                stops.append(newStop)
                                pickerTargetId = newStop.id
                            } label: {
                                Label("Add Stop", systemImage: "plus.circle")
                            }

                            if let limit = access.stopsPerRouteLimit {
                                Text("\(stops.count) of \(limit) stops used (\(access.tier.displayName) plan)")
                                    .font(.caption)
                                    .foregroundColor(stops.count >= limit ? .orange : .secondary)
                            }

                            if stops.count > 2 {
                                Button {
                                    if access.canAccessRouteOptimization() {
                                        stops = RouteOptimizationService.optimize(
                                            stops,
                                            startCoordinate: startCoordinate,
                                            endCoordinate: endCoordinate
                                        )
                                    } else {
                                        upgradeReason = "Route Optimization"
                                        showUpgradePrompt = true
                                    }
                                } label: {
                                    Label("Optimize Route", systemImage: "wand.and.stars")
                                }
                            }
                        } header: {
                            // Edit/Done lives here rather than in the
                            // navigation bar. Up there it sat beside
                            // Cancel as a second, unlabelled control
                            // that looked like it applied to the whole
                            // screen, when all it does is put THIS list
                            // into reorder/delete mode. Next to the
                            // list it governs, it reads as what it is.
                            HStack {
                                Text("Stops")
                                Spacer()
                                EditButton()
                                    .font(.body)
                                    .textCase(nil)
                            }
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
                UpgradeRequiredView(featureName: upgradeReason, requiredTier: .premium)
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

    // A plain iconless tap target, used only for the one action that
    // stays visible inline (viewing notification history) rather than
    // living in the overflow menu below.
    private func rowActionButton(_ title: String, color: Color = .yellow, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .foregroundColor(color)
                .padding(.vertical, 4)
        }
        .contentShape(Rectangle())
        .buttonStyle(.borderless)
    }

    // The link, the SMS and the usage record all happen server-side
    // (sendTrackingLink) - same reason as every other customer message:
    // entitlement, consent and the Twilio credentials must not be
    // decided or held on a device. Re-sending reuses the customer's
    // existing link rather than orphaning a page they already have open.
    private func sendTrackingLink(for stop: Stop) {
        sendingLinkStopId = stop.id
        trackingLinkResults[stop.id] = nil
        Task {
            do {
                let result = try await Functions.functions()
                    .httpsCallable("sendTrackingLink")
                    .call(["routeId": routeId, "stopId": stop.id])
                let data = result.data as? [String: Any]
                let status = data?["deliveryStatus"] as? String ?? "unknown"
                await MainActor.run {
                    trackingLinkResults[stop.id] = trackingLinkMessage(for: status, data: data)
                    sendingLinkStopId = nil
                }
            } catch {
                await MainActor.run {
                    trackingLinkResults[stop.id] = "⚠️ Couldn't send - \(error.localizedDescription)"
                    sendingLinkStopId = nil
                }
            }
        }
    }

    private func trackingLinkMessage(for status: String, data: [String: Any]?) -> String {
        switch status {
        case "accepted":       return "✓ Tracking link texted to the customer."
        case "not_opted_in":   return "⚠️ This customer hasn't agreed to receive messages yet."
        case "channel_disabled": return "⚠️ This customer has text messages turned off."
        case "no_contact_on_file": return "⚠️ No phone number on file for this customer."
        case "not_entitled":   return "⚠️ Your plan doesn't include customer notifications."
        case "failed":
            let reason = data?["failureReason"] as? String
            return "⚠️ Failed to send\(reason.map { " - \($0)" } ?? ".")"
        default:               return "⚠️ \(status)"
        }
    }

    @ViewBuilder
    private func stopRow(_ stop: Stop) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
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
                    if let notes = stop.driverNotes, !notes.isEmpty {
                        Label(notes, systemImage: "note.text")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                } else {
                    // Legacy stop, created before customer linking existed -
                    // still works via its own cached fields (see
                    // NotificationService). Linking it to a real customer
                    // record now lives in the overflow menu, not inline.
                    if let name = stop.customerName, !name.isEmpty {
                        Text(name).font(.headline)
                        Text(stop.address).font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(stop.address).font(.caption).foregroundColor(.secondary)
                    }
                }

                if originalStopIds.contains(stop.id) {
                    rowActionButton("View Notification Log") {
                        historyStop = stop
                    }

                    // For customers who'd rather check on their own than
                    // be texted at every step - one message with a link
                    // instead of a stream of ETA/status updates. Only
                    // offered where there's actually a number to send to.
                    if let phone = stop.customerPhone, !phone.isEmpty {
                        rowActionButton(
                            sendingLinkStopId == stop.id ? "Sending…" : "Send Tracking Link"
                        ) {
                            sendTrackingLink(for: stop)
                        }
                        .disabled(sendingLinkStopId != nil)
                    }

                    if let result = trackingLinkResults[stop.id] {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                    }
                }
            }

            Spacer(minLength: 8)

            // Live, immediate overrides - not staged into the Save
            // button below, which batches a local snapshot taken when
            // this screen opened and would risk overwriting whatever a
            // driver has done since. These write straight to Firestore
            // the moment they're tapped:
            // - a driver marked something complete that wasn't theirs
            //   to finish (undo it)
            // - the owner/manager did a stop themselves while driving
            //   by (mark it done directly)
            // - one driver finished early and can take over a stop
            //   still sitting on someone else's route (move it)
            //
            // Mark Complete only applies to a stop that's actually
            // saved to Firestore, so it's gated on originalStopIds; the
            // overflow menu stays available for every stop (including
            // ones just added and not yet saved) since selecting a
            // customer has to work before that first save too.
            if originalStopIds.contains(stop.id) {
                Button {
                    toggleCompletion(stop)
                } label: {
                    Image(systemName: stop.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(stop.isCompleted ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }

            Menu {
                if stop.customerId != nil {
                    Button("Change Customer") {
                        pickerTargetId = stop.id
                    }
                } else {
                    Button(stop.customerName?.isEmpty == false ? "Link to a Customer Record" : "Select Customer") {
                        pickerTargetId = stop.id
                    }
                }
                if originalStopIds.contains(stop.id) {
                    Button("Move to Another Route") {
                        moveTargetStop = stop
                        loadOtherRoutes()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 44, height: 44)
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
        stops[index].driverNotes = customer.notes
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
                    startAddress = route.startAddress ?? ""
                    startLatitude = route.startLatitude
                    startLongitude = route.startLongitude
                    endAddress = route.endAddress ?? ""
                    endLatitude = route.endLatitude
                    endLongitude = route.endLongitude
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
                originalStopCustomers = Dictionary(
                    fetched.map { ($0.id, customerIdentity(of: $0)) },
                    uniquingKeysWith: { first, _ in first }
                )
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

        let trimmedStartAddress = startAddress.trimmingCharacters(in: .whitespaces)
        let trimmedEndAddress = endAddress.trimmingCharacters(in: .whitespaces)

        routeRepo.updateRoute(
            routeId: routeId,
            name: routeName,
            driverId: selectedDriverId,
            startAddress: trimmedStartAddress.isEmpty ? nil : trimmedStartAddress,
            startLatitude: trimmedStartAddress.isEmpty ? nil : startLatitude,
            startLongitude: trimmedStartAddress.isEmpty ? nil : startLongitude,
            endAddress: trimmedEndAddress.isEmpty ? nil : trimmedEndAddress,
            endLatitude: trimmedEndAddress.isEmpty ? nil : endLatitude,
            endLongitude: trimmedEndAddress.isEmpty ? nil : endLongitude
        ) { success in
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
                // saveRouteEdits, not saveStops: this array was frozen
                // when the form opened (see loadEverything), so writing
                // it back wholesale reverted every stop the crew had
                // completed since and deleted their timing data. This
                // writes only the fields this screen edits.
                let stopsSaved = await withCheckedContinuation { continuation in
                    stopsRepo.saveRouteEdits(forRoute: routeId, stops: orderedStops) { success in
                        continuation.resume(returning: success)
                    }
                }
                guard stopsSaved else {
                    // The route document itself saved; the stops did
                    // not. Staying open with `stops` untouched is the
                    // point - the owner's reordering and deletions are
                    // still on screen and Save can simply be tapped
                    // again. Dismissing here is what used to throw the
                    // whole edit away while looking like it worked.
                    isSaving = false
                    errorMessage = "Saved the route, but couldn't save the stops - check your connection and tap Save again."
                    return
                }

                // A stop that now means a different person must not
                // keep the previous person's tracking links alive.
                // Those links carry that customer's own name and
                // address, so nothing on their page looks wrong - but
                // the stop underneath is somebody else's now, and the
                // driver would go on publishing position into it right
                // up to parking in the new customer's driveway.
                //
                // Done here rather than in apply() because a re-point
                // isn't real until it's saved; an owner who opens the
                // picker, changes their mind and taps Cancel should
                // not have knocked a live customer's link offline.
                for stop in orderedStops {
                    guard let original = originalStopCustomers[stop.id] else { continue }
                    if original != customerIdentity(of: stop) {
                        trackingRepo.supersedeLinks(forStopId: stop.id)
                    }
                }

                // Removing a stop outright ends its tracking for the
                // same reason - there is no longer a job to watch.
                //
                // Deletions are awaited individually and the failures
                // counted. A stop whose delete fails is still on the
                // route in Firestore, so it must stay in
                // originalStopIds - otherwise the retry would think it
                // had never been asked to delete it, and the stop would
                // quietly come back on the next screen that reads the
                // route.
                let currentIds = Set(orderedStops.map { $0.id })
                var stillPresent: Set<String> = []
                for removedId in originalStopIds.subtracting(currentIds) {
                    trackingRepo.supersedeLinks(forStopId: removedId)
                    let deleted = await withCheckedContinuation { continuation in
                        stopsRepo.deleteStop(routeId: routeId, stopId: removedId) { success in
                            continuation.resume(returning: success)
                        }
                    }
                    if !deleted { stillPresent.insert(removedId) }
                }

                guard stillPresent.isEmpty else {
                    // Everything that DID delete is now genuinely gone,
                    // so drop those from the baseline and leave only
                    // the stragglers. Tapping Save again retries just
                    // those, instead of re-issuing deletes that have
                    // already succeeded.
                    originalStopIds = currentIds.union(stillPresent)
                    isSaving = false
                    errorMessage = stillPresent.count == 1
                        ? "Couldn't remove one stop - check your connection and tap Save again."
                        : "Couldn't remove \(stillPresent.count) stops - check your connection and tap Save again."
                    return
                }

                isSaving = false
                dismiss()
            }
        }
    }
}
