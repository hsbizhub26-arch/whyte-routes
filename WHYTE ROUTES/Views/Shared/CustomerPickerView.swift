import SwiftUI

// The actual fix for "routes and customers are two disconnected
// lists" - replaces manually typing a stop's name/address with
// picking a real Customer record (or creating one inline, which
// still ends up linked - never an orphaned unlinked stop from here
// on). Selecting a customer hands back the full record so the caller
// can fill in the stop's cached fields AND store customerId.
struct CustomerPickerView: View {

    var onSelect: (Customer) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var access = FeatureAccessManager.shared
    @State private var customers: [Customer] = []
    @State private var isLoading = true
    @State private var showCreateNew = false
    @State private var showUpgradePrompt = false

    private let repo = CustomerRepository()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading customers…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            Button {
                                // Same limit enforced here as on the
                                // Customers tab - this is a second,
                                // separate entry point into customer
                                // creation and must not bypass it.
                                if access.canAddCustomer(currentCount: customers.count) {
                                    showCreateNew = true
                                } else {
                                    showUpgradePrompt = true
                                }
                            } label: {
                                Label("Create New Customer", systemImage: "person.badge.plus")
                            }
                        }

                        if !customers.isEmpty {
                            Section("Existing Customers") {
                                ForEach(customers) { customer in
                                    Button {
                                        onSelect(customer)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(customer.name)
                                                .foregroundColor(.primary)
                                            Text(customer.address)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .readableListWidth()
                }
            }
            .navigationTitle("Select Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $showCreateNew) {
                AddCustomerView { newCustomer in
                    onSelect(newCustomer)
                    dismiss()
                }
            }
            .sheet(isPresented: $showUpgradePrompt) {
                UpgradeRequiredView(
                    featureName: "More Customers",
                    requiredTier: SubscriptionTier(rawValue: access.tier.rawValue + 1) ?? .enterprise
                )
            }
        }
    }

    private func load() {
        repo.fetchCustomers { result in
            Task { @MainActor in
                if case .success(let fetched) = result {
                    customers = fetched
                }
                isLoading = false
            }
        }
    }
}
