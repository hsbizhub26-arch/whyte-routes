import SwiftUI

// Was a literal placeholder ("Driver picker goes here…") - a manager
// tapping "Assign Driver" got a screen that did nothing. This is the
// real version, matching the driver-assignment picker Owner's
// EditRouteView already has.
struct ManagerAssignDriverSheet: View {

    var route: Route

    @Environment(\.dismiss) private var dismiss
    @State private var drivers: [Driver] = []
    @State private var selectedDriverId: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let driverRepo: DriverRepository = FirestoreDriverRepository()
    private let routeRepo = RouteRepository()

    var body: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    Text(route.name)
                        .font(.headline)
                }

                Section("Assign to") {
                    if drivers.isEmpty {
                        Text("No drivers yet - invite one from Team first.")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Driver", selection: $selectedDriverId) {
                            Text("Unassigned").tag(String?.none)
                            ForEach(drivers) { driver in
                                Text(driver.name).tag(String?.some(driver.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle("Assign Driver")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(isSaving || selectedDriverId == nil)
                }
            }
            .onAppear {
                selectedDriverId = route.driverId
                driverRepo.fetchDrivers { result in
                    Task { @MainActor in
                        if case .success(let fetched) = result {
                            drivers = fetched.sorted { $0.name < $1.name }
                        }
                    }
                }
            }
        }
    }

    private func save() {
        guard let selectedDriverId else { return }
        isSaving = true
        errorMessage = nil
        routeRepo.assignDriver(routeId: route.id, driverId: selectedDriverId) { success in
            Task { @MainActor in
                isSaving = false
                if success {
                    dismiss()
                } else {
                    errorMessage = "Couldn't assign this driver - check your connection and try again."
                }
            }
        }
    }
}
