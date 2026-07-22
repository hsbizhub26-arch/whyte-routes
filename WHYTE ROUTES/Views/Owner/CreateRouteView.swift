import SwiftUI

// Minimal route-building screen. There was previously no way anywhere
// in the app to create a route at all - AssignRoutesView could only
// assign a driver to a route that already existed. This is the
// smallest form that fills that gap: name a route, list its stops,
// optionally assign a driver up front, save.
//
// Stops are built by picking a real Customer record (or creating one
// inline) rather than retyping name/address/phone/email by hand -
// see CustomerPickerView. Geocoding (lat/lng) comes along with the
// customer's own address; DriverMapView already skips stops with no
// coordinate rather than crashing, so a customer without coordinates
// on file is still safe, just won't show a map pin yet.
struct CreateRouteView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var routeName = ""
    @State private var stops: [StopDraft] = []
    @State private var drivers: [Driver] = []
    @State private var selectedDriverId: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pickerTargetId: UUID?

    private let driverRepo = FirestoreDriverRepository()

    struct StopDraft: Identifiable {
        let id = UUID()
        var customerId: String?
        var customerName: String = ""
        var customerPhone: String = ""
        var customerEmail: String = ""
        var customerOptedIn: Bool = false
        var driverNotes: String = ""
        var address: String = ""
        var latitude: Double?
        var longitude: Double?
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    TextField("Route name (e.g. Monday - North Side)", text: $routeName)
                }

                Section("Driver") {
                    Picker("Assign to", selection: $selectedDriverId) {
                        Text("Unassigned for now").tag(String?.none)
                        ForEach(drivers) { driver in
                            Text(driver.name).tag(String?.some(driver.id))
                        }
                    }
                }

                Section("Stops") {
                    ForEach(stops) { stop in
                        stopRow(stop)
                    }
                    .onDelete { stops.remove(atOffsets: $0) }

                    Button {
                        let draft = StopDraft()
                        stops.append(draft)
                        pickerTargetId = draft.id
                    } label: {
                        Label("Add Stop", systemImage: "plus.circle")
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle("New Route")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(!isFormValid || isSaving)
                }
            }
            .onAppear(perform: loadDrivers)
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
    private func stopRow(_ stop: StopDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if stop.customerId != nil {
                Text(stop.customerName)
                    .font(.headline)
                Text(stop.address)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !stop.customerPhone.isEmpty {
                    Text(stop.customerPhone)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("Change Customer") {
                    pickerTargetId = stop.id
                }
                .font(.footnote)
            } else {
                Button {
                    pickerTargetId = stop.id
                } label: {
                    Label("Select Customer", systemImage: "person.crop.circle.badge.plus")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func apply(_ customer: Customer, toStopId id: UUID?) {
        guard let id, let index = stops.firstIndex(where: { $0.id == id }) else { return }
        stops[index].customerId = customer.id
        stops[index].customerName = customer.name
        stops[index].customerPhone = customer.phone ?? ""
        stops[index].customerEmail = customer.email ?? ""
        stops[index].customerOptedIn = customer.notificationsOptIn
        stops[index].driverNotes = customer.notes ?? ""
        stops[index].address = customer.address
        stops[index].latitude = customer.latitude
        stops[index].longitude = customer.longitude
    }

    private var isFormValid: Bool {
        !routeName.trimmingCharacters(in: .whitespaces).isEmpty
            && stops.contains { $0.customerId != nil }
    }

    private func loadDrivers() {
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

        RouteService.shared.createRoute(name: routeName, driverId: selectedDriverId) { routeId in
            Task { @MainActor in
                guard let routeId else {
                    isSaving = false
                    errorMessage = "Couldn't create the route - check your connection and try again."
                    return
                }

                let validStops = stops
                    .filter { $0.customerId != nil }
                    .enumerated()
                    .map { index, draft in
                        Stop(
                            customerId: draft.customerId,
                            customerName: draft.customerName.isEmpty ? nil : draft.customerName,
                            customerPhone: draft.customerPhone.isEmpty ? nil : draft.customerPhone,
                            customerEmail: draft.customerEmail.isEmpty ? nil : draft.customerEmail,
                            customerOptedIn: draft.customerOptedIn,
                            driverNotes: draft.driverNotes.isEmpty ? nil : draft.driverNotes,
                            address: draft.address,
                            latitude: draft.latitude,
                            longitude: draft.longitude,
                            order: index,
                            driverId: selectedDriverId
                        )
                    }

                RouteService.shared.saveStops(for: routeId, validStops)

                if let selectedDriverId {
                    driverRepo.assignRoute(driverId: selectedDriverId, routeId: routeId)
                }

                isSaving = false
                dismiss()
            }
        }
    }
}
