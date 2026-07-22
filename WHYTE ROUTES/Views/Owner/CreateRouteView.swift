import SwiftUI

// Minimal route-building screen. There was previously no way anywhere
// in the app to create a route at all - AssignRoutesView could only
// assign a driver to a route that already existed. This is the
// smallest form that fills that gap: name a route, list its stops,
// optionally assign a driver up front, save. Geocoding (lat/lng) isn't
// wired here - DriverMapView already skips stops with no coordinate
// rather than crashing, so an address-only stop is safe, just won't
// show a map pin yet.
struct CreateRouteView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var routeName = ""
    @State private var stops: [StopDraft] = [StopDraft()]
    @State private var drivers: [Driver] = []
    @State private var selectedDriverId: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let driverRepo = FirestoreDriverRepository()

    struct StopDraft: Identifiable {
        let id = UUID()
        var customerName: String = ""
        var address: String = ""
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
                    ForEach($stops) { $stop in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Customer name", text: $stop.customerName)
                            TextField("Address", text: $stop.address)
                        }
                    }
                    .onDelete { stops.remove(atOffsets: $0) }

                    Button {
                        stops.append(StopDraft())
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
        }
    }

    private var isFormValid: Bool {
        !routeName.trimmingCharacters(in: .whitespaces).isEmpty
            && stops.contains { !$0.address.trimmingCharacters(in: .whitespaces).isEmpty }
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
                    .filter { !$0.address.trimmingCharacters(in: .whitespaces).isEmpty }
                    .enumerated()
                    .map { index, draft in
                        Stop(
                            customerName: draft.customerName.isEmpty ? nil : draft.customerName,
                            address: draft.address,
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
