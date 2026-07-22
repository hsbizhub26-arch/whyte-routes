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
    @State private var showAddCustomer = false

    var body: some View {
        NavigationStack {
            VStack {
                TextField("Search customers…", text: $vm.search)
                    .textFieldStyle(.roundedBorder)
                    .padding()

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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(customer.name).font(.headline)
                            Text(customer.address).font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Customers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddCustomer = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAddCustomer) {
                AddCustomerView { vm.load() }
            }
        }
    }
}
