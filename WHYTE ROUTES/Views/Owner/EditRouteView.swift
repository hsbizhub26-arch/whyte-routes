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

    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()
    private let driverRepo = FirestoreDriverRepository()

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
                        } header: {
                            Text("Stops")
                        } footer: {
                            Text("Drag to reorder - the driver sees stops in this order.")
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
        }
    }

    @ViewBuilder
    private func stopRow(_ stop: Stop) -> some View {
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
                Button("Change Customer") {
                    pickerTargetId = stop.id
                }
                .font(.footnote)
            } else {
                // Legacy stop, created before customer linking existed -
                // still works via its own cached fields (see
                // NotificationService), but offer an easy upgrade path.
                if let name = stop.customerName, !name.isEmpty {
                    Text(name).font(.headline)
                    Text(stop.address).font(.caption).foregroundColor(.secondary)
                }
                Button(stop.customerName?.isEmpty == false ? "Link to a Customer Record" : "Select Customer") {
                    pickerTargetId = stop.id
                }
                .font(.footnote)
            }

            if originalStopIds.contains(stop.id) {
                Button("View Notification Log") {
                    historyStop = stop
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 2)
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
