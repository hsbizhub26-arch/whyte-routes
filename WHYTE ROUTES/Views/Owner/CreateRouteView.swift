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
    @State private var showStopLimitPrompt = false
    // Quick-add (ad-hoc stop). `quickResolved` holds the address MapKit
    // actually resolved, kept apart from the text in the box so the two
    // can be compared before anything is written.
    @State private var quickAddress = ""
    @State private var quickResolved: ResolvedAddress?

    private let driverRepo = FirestoreDriverRepository()
    private let access = FeatureAccessManager.shared

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

    struct ResolvedAddress {
        let address: String
        let latitude: Double
        let longitude: Double
    }

    /// Inert until the text in the box is EXACTLY the address MapKit
    /// resolved - otherwise the coordinates on hand belong to a
    /// different address than the one on screen.
    private var quickAddIsReady: Bool {
        guard let resolved = quickResolved else { return false }
        return !quickAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && resolved.address == quickAddress
    }

    private func addQuickStop() {
        guard quickAddIsReady, let resolved = quickResolved else { return }
        guard access.canAddStop(currentCount: stops.count) else {
            showStopLimitPrompt = true
            return
        }
        var draft = StopDraft()
        draft.address = resolved.address
        draft.latitude = resolved.latitude
        draft.longitude = resolved.longitude
        stops.append(draft)
        quickAddress = ""
        quickResolved = nil
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
                    // Ad-hoc stop, no Customer record required. Without
                    // this the ONLY way to fill a draft was the customer
                    // picker, so relaxing the customerId requirement at
                    // save would have had nothing to let through.
                    VStack(alignment: .leading, spacing: 6) {
                        AddressAutocompleteField(
                            address: $quickAddress,
                            placeholder: "Add a stop by address"
                        ) { address, lat, lng in
                            // A 0,0 fix means the resolve failed; writing
                            // it would send a driver into the Atlantic.
                            guard !(lat == 0 && lng == 0) else { return }
                            quickAddress = address
                            quickResolved = ResolvedAddress(
                                address: address, latitude: lat, longitude: lng
                            )
                        }

                        Button {
                            addQuickStop()
                        } label: {
                            Label("Add This Address", systemImage: "plus.circle.fill")
                                .font(.footnote.bold())
                                .foregroundColor(quickAddIsReady ? .yellow : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        .disabled(!quickAddIsReady)

                        if !quickAddress.isEmpty && !quickAddIsReady {
                            Text("Pick the address from the suggestions so the stop gets real coordinates.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)

                    ForEach(stops) { stop in
                        stopRow(stop)
                    }
                    .onDelete { stops.remove(atOffsets: $0) }

                    Button {
                        guard access.canAddStop(currentCount: stops.count) else {
                            showStopLimitPrompt = true
                            return
                        }
                        let draft = StopDraft()
                        stops.append(draft)
                        pickerTargetId = draft.id
                    } label: {
                        Label("Add Stop", systemImage: "plus.circle")
                    }

                    if let limit = access.stopsPerRouteLimit {
                        Text("\(stops.count) of \(limit) stops used (\(access.tier.displayName) plan)")
                            .font(.caption)
                            .foregroundColor(stops.count >= limit ? .orange : .secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            .readableListWidth()
            .navigationTitle("New Route")
            .sheet(isPresented: $showStopLimitPrompt) {
                UpgradeRequiredView(featureName: "More Stops Per Route", requiredTier: .premium)
            }
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
            } else if !stop.address.isEmpty {
                // Ad-hoc stop. It has an address and real coordinates, so
                // it is a complete, drivable stop already - showing only a
                // "Select Customer" button here (as this row used to) hid
                // the address entirely and made it look unfinished.
                Text(stop.address)
                    .font(.subheadline)
                Button("Link to a Customer Record") {
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
        // An address is all a stop actually needs. Requiring a linked
        // Customer record here meant a dispatcher could not add the
        // one-off jobs that come in mid-storm without first creating a
        // customer profile for a driveway they may never service again.
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

                // Was .filter { $0.customerId != nil } - which silently
                // DROPPED every address-only stop at save. The real
                // requirement is an address to drive to.
                let validStops = stops
                    .filter { !$0.address.trimmingCharacters(in: .whitespaces).isEmpty }
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
