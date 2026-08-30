import SwiftUI

// Same gap as routes had: CustomerRepository.createCustomer already
// existed, but nothing in the app ever called it - CustomerListView
// could only ever show an empty list. This is the minimal form that
// fills it.
struct AddCustomerView: View {

    @Environment(\.dismiss) private var dismiss
    var existingCustomer: Customer? = nil
    var onSaved: (Customer) -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var notes = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0
    @State private var notificationsOptIn = false
    @State private var consentTimestamp: Date? = nil
    @State private var smsEnabled = true
    @State private var emailEnabled = true
    @State private var notifyEta15 = false
    @State private var notifyEta10 = false
    @State private var notifyCompleted = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    // Guards the consent-timestamp side effect below from firing
    // during the initial onAppear hydration - without this, loading
    // an existing opted-in customer (notificationsOptIn false->true
    // as the saved value loads in) could fire the same onChange as a
    // real user toggle and stamp today's date over their true
    // original consent date, depending on exactly how SwiftUI batches
    // the two separate state assignments in onAppear. Real user
    // toggles always happen well after onAppear has finished.
    @State private var hasLoadedInitialValues = false

    private let repo = CustomerRepository()

    private var isEditing: Bool { existingCustomer != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Name", text: $name)
                    AddressAutocompleteField(address: $address) { _, lat, lng in
                        latitude = lat
                        longitude = lng
                    }
                    if !address.isEmpty && latitude == 0 && longitude == 0 {
                        Text("Select an address suggestion from the list - typing without picking one leaves this customer with no real location on the map.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }

                Section {
                    TextField("e.g. gate code 1234, no scrape driveway, dog in yard", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes for Drivers")
                } footer: {
                    Text("Shown right on the stop screen every time a driver works this property.")
                }

                Section {
                    Toggle("Customer agreed to receive service notifications", isOn: $notificationsOptIn)
                        .onChange(of: notificationsOptIn) { _, newValue in
                            // Always re-stamp on every false->true transition,
                            // not just the first one - a customer who opts
                            // out and later opts back in has genuinely
                            // re-consented at a new moment. Freezing the
                            // original date here would silently hide that
                            // a withdrawal + re-consent ever happened.
                            if newValue && hasLoadedInitialValues {
                                consentTimestamp = Date()
                            }
                        }
                    if let consentTimestamp {
                        Text("Consent given \(consentTimestamp.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("Required before any arrival/completion notification can be sent to this customer.")
                }

                if notificationsOptIn {
                    Section("Channels") {
                        Toggle("Text message (SMS)", isOn: $smsEnabled)
                        Toggle("Email", isOn: $emailEnabled)
                    }
                    Section {
                        Toggle("Driver ~15 min away", isOn: $notifyEta15)
                        Toggle("Driver ~10 min away", isOn: $notifyEta10)
                        Toggle("Service completed", isOn: $notifyCompleted)
                    } header: {
                        Text("Which updates")
                    } footer: {
                        Text("Turn any of these off to stop just that one - the consent above still covers the rest.")
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle(isEditing ? "Edit Customer" : "Add Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(!isFormValid || isSaving)
                }
            }
            .onAppear {
                // Runs for both branches below - a brand-new customer
                // has nothing to hydrate, but still needs the flag set
                // so their first real toggle (a genuine user action,
                // not a load artifact) stamps a consent date.
                defer { hasLoadedInitialValues = true }
                guard let existingCustomer else { return }
                name = existingCustomer.name
                address = existingCustomer.address
                phone = existingCustomer.phone ?? ""
                email = existingCustomer.email ?? ""
                notes = existingCustomer.notes ?? ""
                latitude = existingCustomer.latitude
                longitude = existingCustomer.longitude
                notificationsOptIn = existingCustomer.notificationsOptIn
                consentTimestamp = existingCustomer.consentTimestamp
                smsEnabled = existingCustomer.smsEnabled
                emailEnabled = existingCustomer.emailEnabled
                notifyEta15 = existingCustomer.notifyEta15
                notifyEta10 = existingCustomer.notifyEta10
                notifyCompleted = existingCustomer.notifyCompleted
            }
        }
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
            && (latitude != 0 || longitude != 0)
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        // latitude/longitude come from AddressAutocompleteField's
        // resolved suggestion; stay 0 only if the address was typed
        // freehand without picking a suggestion.
        let customer = Customer(
            id: existingCustomer?.id ?? UUID().uuidString,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            phone: phone.isEmpty ? nil : phone,
            email: email.isEmpty ? nil : email,
            notes: notes.isEmpty ? nil : notes,
            notificationsOptIn: notificationsOptIn,
            consentTimestamp: consentTimestamp,
            smsEnabled: smsEnabled,
            emailEnabled: emailEnabled,
            notifyEta15: notifyEta15,
            notifyEta10: notifyEta10,
            notifyCompleted: notifyCompleted
        )

        let onComplete: (Bool) -> Void = { success in
            Task { @MainActor in
                isSaving = false
                if success {
                    onSaved(customer)
                    dismiss()
                } else {
                    errorMessage = "Couldn't save the customer - check your connection and try again."
                }
            }
        }

        if isEditing {
            repo.updateCustomer(customer, completion: onComplete)
        } else {
            repo.createCustomer(customer, completion: onComplete)
        }
    }
}
