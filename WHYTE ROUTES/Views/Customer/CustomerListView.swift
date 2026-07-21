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

    var body: some View {
        VStack {
            TextField("Search customers…", text: $vm.search)
                .textFieldStyle(.roundedBorder)
                .padding()

            if vm.isLoading {
                ProgressView("Loading customers…")
                Spacer()
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
    }
}
