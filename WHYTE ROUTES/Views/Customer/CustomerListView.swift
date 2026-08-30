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

    /// Removes the customer locally first so the row disappears under
    /// the finger, then writes. On failure the row comes back and the
    /// caller is told - better than a row that vanishes and silently
    /// returns on the next load.
    func delete(_ customer: Customer, onFailure: @escaping () -> Void) {
        let previous = customers
        customers.removeAll { $0.id == customer.id }

        repo.deleteCustomer(id: customer.id) { ok in
            Task { @MainActor in
                guard !ok else { return }
                self.customers = previous
                onFailure()
            }
        }
    }
}

struct CustomerListView: View {

    @StateObject private var vm = CustomerListViewModel()
    @ObservedObject private var access = FeatureAccessManager.shared
    @State private var showAddCustomer = false
    @State private var showUpgradePrompt = false
    @State private var editingCustomer: Customer?
    /// Set by the swipe action; drives the confirmation. Deleting a
    /// customer is not undoable, so it does not happen on the swipe
    /// alone.
    @State private var pendingDelete: Customer?
    @State private var deleteFailed = false

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
                        // Swipe to delete. Not `.onDelete`, because this
                        // List is built from `filtered` - onDelete hands
                        // back an IndexSet into the FILTERED array, so
                        // deleting while a search is active would remove
                        // whichever customer happened to sit at that
                        // index of the unfiltered list instead. Binding
                        // the action to this row's own customer removes
                        // the one actually swiped.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = customer
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
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
            .confirmationDialog(
                pendingDelete.map { "Delete \($0.name)?" } ?? "Delete customer?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Customer", role: .destructive) {
                    guard let customer = pendingDelete else { return }
                    pendingDelete = nil
                    vm.delete(customer) { deleteFailed = true }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This removes them from your customer list and stops any further notifications. Routes already built keep the stop.")
            }
            .alert("Couldn't delete that customer", isPresented: $deleteFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again.")
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
