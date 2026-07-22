import SwiftUI
import Combine

@MainActor
final class CustomerListViewModel: ObservableObject {
    @Published var customers: [Customer] = []
    @Published var search = ""
    @Published var isLoading = true

    private let repo = CustomerRepository()

    init() { load() }

    func load() {
        repo.fetchCustomers { result in
            Task { @MainActor in
                switch result {
                case .success(let list):
                    self.customers = list
                case .failure:
                    self.customers = []
                }
                self.isLoading = false
            }
        }
    }

    var filtered: [Customer] {
        if search.isEmpty { return customers }
        return customers.filter {
            $0.name.lowercased().contains(search.lowercased()) ||
            $0.address.lowercased().contains(search.lowercased())
        }
    }
}

struct CustomerListView: View {

    @StateObject private var vm = CustomerListViewModel()
    @ObservedObject private var access = FeatureAccessManager.shared
    @State private var showAddCustomer = false
    @State private var showUpgradePrompt = false
    @State private var editingCustomer: Customer?

    var body: some View {
        NavigationStack {
            VStack {
                TextField("Search customers…", text: $vm.search)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                if let limit = access.customerLimit {
                    Text("\(vm.customers.count) of \(limit) customers used (\(access.tier.displayName) plan)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                if vm.isLoading {
                    ProgressView("Loading customers…")
                    Spacer()
                } else if vm.customers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No customers yet")
                            .font(.headline)
                        Text("Tap + to add your first customer.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(vm.filtered) { customer in
                        Button {
                            editingCustomer = customer
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(customer.name).font(.headline)
                                Text(customer.address).font(.subheadline).foregroundColor(.secondary)
                                if let notes = customer.notes, !notes.isEmpty {
                                    Label(notes, systemImage: "note.text")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                        .lineLimit(1)
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Customers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // Checked here, not just at save time, so a
                        // company at its limit never even sees the
                        // form - no path exists to create past it.
                        if access.canAddCustomer(currentCount: vm.customers.count) {
                            showAddCustomer = true
                        } else {
                            showUpgradePrompt = true
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAddCustomer) {
                AddCustomerView { _ in vm.load() }
            }
            .sheet(item: $editingCustomer) { customer in
                AddCustomerView(existingCustomer: customer) { _ in vm.load() }
            }
            .sheet(isPresented: $showUpgradePrompt) {
                UpgradeRequiredView(
                    featureName: "More Customers",
                    requiredTier: SubscriptionTier(rawValue: access.tier.rawValue + 1) ?? .enterprise
                )
            }
        }
    }
}
