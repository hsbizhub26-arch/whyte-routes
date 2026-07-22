import SwiftUI

// Same gap as routes had: CustomerRepository.createCustomer already
// existed, but nothing in the app ever called it - CustomerListView
// could only ever show an empty list. This is the minimal form that
// fills it.
struct AddCustomerView: View {

    @Environment(\.dismiss) private var dismiss
    var onSaved: () -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0
    @State private var notificationsOptIn = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let repo = CustomerRepository()

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Name", text: $name)
                    AddressAutocompleteField(address: $address) { _, lat, lng in
                        latitude = lat
                        longitude = lng
                    }
                }

                Section {
                    Toggle("Customer agreed to receive service notifications", isOn: $notificationsOptIn)
                } footer: {
                    Text("Required before any arrival/completion notification can be sent to this customer.")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle("Add Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(!isFormValid || isSaving)
                }
            }
        }
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        // latitude/longitude come from AddressAutocompleteField's
        // resolved suggestion; stay 0 only if the address was typed
        // freehand without picking a suggestion.
        let customer = Customer(
            id: UUID().uuidString,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            notificationsOptIn: notificationsOptIn
        )

        repo.createCustomer(customer) { success in
            Task { @MainActor in
                isSaving = false
                if success {
                    onSaved()
                    dismiss()
                } else {
                    errorMessage = "Couldn't save the customer - check your connection and try again."
                }
            }
        }
    }
}
