import SwiftUI
import FirebaseFirestore

// The actual fix for "routes and customers are two disconnected
// lists" - replaces manually typing a stop's name/address with
// picking a real Customer record (or creating one inline, which
// still ends up linked - never an orphaned unlinked stop from here
// on). Selecting a customer hands back the full record so the caller
// can fill in the stop's cached fields AND store customerId.
//
// Built to answer "who haven't I put on a route yet?" at a glance:
//   • newest customers first, with the date they were added
//   • customers on NO route get their own section at the top
//   • everyone else says which route they're already on
//   • customers already on the route being edited are greyed out and
//     can't be picked twice
struct CustomerPickerView: View {

    /// The route being edited (nil while creating a new one). Its saved
    /// stops are ignored in favour of `onThisRoute`, which reflects the
    /// editor's unsaved changes.
    var currentRouteId: String? = nil
    /// Customer ids already on the route being built/edited, including
    /// stops added in this editing session that aren't saved yet.
    var onThisRoute: Set<String> = []
    /// When set, the picker is a checklist (Select All / Unselect All,
    /// then "Add (N)") instead of tap-one-and-close. Used when adding
    /// new stops; changing the customer on an existing stop stays
    /// single-pick.
    var onSelectMany: (([Customer]) -> Void)? = nil
    var onSelect: (Customer) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var isMultiSelect: Bool { onSelectMany != nil }

    /// What Select All acts on: every customer currently shown (so it
    /// respects the search) that isn't already on this route.
    private var selectableVisible: [Customer] { notOnAnyRoute + onOtherRoutes }

    private var allVisibleSelected: Bool {
        !selectableVisible.isEmpty && selectableVisible.allSatisfy { selected.contains($0.id) }
    }
    @ObservedObject private var access = FeatureAccessManager.shared
    @State private var customers: [Customer] = []
    /// customerId -> names of the OTHER routes they're on.
    @State private var routesByCustomer: [String: [String]] = [:]
    /// Same, keyed by normalised address, for older stops that were
    /// typed in before stops were linked to customer records.
    @State private var routesByAddress: [String: [String]] = [:]
    @State private var isLoading = true
    @State private var search = ""
    @State private var showCreateNew = false
    @State private var showUpgradePrompt = false

    private let repo = CustomerRepository()

    // MARK: - Grouping

    private func otherRoutes(for c: Customer) -> [String] {
        let names = routesByCustomer[c.id] ?? routesByAddress[Self.addressKey(c.address)] ?? []
        return Array(Set(names)).sorted()
    }

    private var filtered: [Customer] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? customers : customers.filter {
            $0.name.lowercased().contains(q) || $0.address.lowercased().contains(q)
        }
        return Self.newestFirst(list)
    }

    /// Newest first; records with no date go last, alphabetically.
    private static func newestFirst(_ list: [Customer]) -> [Customer] {
        list.sorted { a, b in
            switch (a.createdAt, b.createdAt) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    private var notOnAnyRoute: [Customer] {
        filtered.filter { !onThisRoute.contains($0.id) && otherRoutes(for: $0).isEmpty }
    }
    private var onOtherRoutes: [Customer] {
        filtered.filter { !onThisRoute.contains($0.id) && !otherRoutes(for: $0).isEmpty }
    }
    private var alreadyHere: [Customer] {
        filtered.filter { onThisRoute.contains($0.id) }
    }

    // MARK: - View

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

                        if isMultiSelect && !selectableVisible.isEmpty {
                            Section {
                                HStack {
                                    Button("Select All") {
                                        selected.formUnion(selectableVisible.map(\.id))
                                    }
                                    .disabled(allVisibleSelected)
                                    Spacer()
                                    Text("\(selected.count) selected")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button("Unselect All") {
                                        selected.removeAll()
                                    }
                                    .disabled(selected.isEmpty)
                                }
                                // Two buttons in one row: without this a tap
                                // anywhere fires both.
                                .buttonStyle(.borderless)
                            }
                        }

                        if !notOnAnyRoute.isEmpty {
                            Section {
                                ForEach(notOnAnyRoute) { row($0, routes: []) }
                            } header: {
                                Text("Not on a route yet · \(notOnAnyRoute.count)")
                            }
                        } else if !customers.isEmpty && search.isEmpty {
                            Section {
                                Label("Every customer is on a route", systemImage: "checkmark.circle")
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !onOtherRoutes.isEmpty {
                            Section("Already on a route · \(onOtherRoutes.count)") {
                                ForEach(onOtherRoutes) { row($0, routes: otherRoutes(for: $0)) }
                            }
                        }

                        if !alreadyHere.isEmpty {
                            Section("On this route · \(alreadyHere.count)") {
                                ForEach(alreadyHere) { c in
                                    HStack {
                                        details(c)
                                        Spacer()
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .opacity(0.5)
                                }
                            }
                        }
                    }
                    .readableListWidth()
                    .searchable(text: $search, prompt: "Search name or address")
                }
            }
            .navigationTitle("Select Customer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if let onSelectMany {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.isEmpty ? "Add" : "Add (\(selected.count))") {
                            // Same newest-first order the list shows.
                            let picked = Self.newestFirst(customers.filter { selected.contains($0.id) })
                            onSelectMany(picked)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(selected.isEmpty)
                    }
                }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $showCreateNew) {
                AddCustomerView { newCustomer in
                    if isMultiSelect {
                        // Stay open: the new customer joins the list,
                        // already ticked, alongside anything else picked.
                        customers.append(newCustomer)
                        selected.insert(newCustomer.id)
                    } else {
                        onSelect(newCustomer)
                        dismiss()
                    }
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

    private func row(_ customer: Customer, routes: [String]) -> some View {
        Button {
            if isMultiSelect {
                if selected.contains(customer.id) {
                    selected.remove(customer.id)
                } else {
                    selected.insert(customer.id)
                }
            } else {
                onSelect(customer)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                if isMultiSelect {
                    Image(systemName: selected.contains(customer.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(selected.contains(customer.id) ? .accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    details(customer)
                    if !routes.isEmpty {
                        Label("On: " + routes.joined(separator: ", "), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    private func details(_ customer: Customer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(customer.name)
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                if let added = customer.createdAt {
                    Text(Self.addedLabel(added))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Text(customer.address)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Loading

    private func load() {
        let group = DispatchGroup()
        var fetchedCustomers: [Customer] = []
        var byCustomer: [String: [String]] = [:]
        var byAddress: [String: [String]] = [:]
        let lock = NSLock()

        group.enter()
        repo.fetchCustomers { result in
            if case .success(let fetched) = result { fetchedCustomers = fetched }
            group.leave()
        }

        // Every route's stops, so each customer can say where they
        // already are. A handful of small reads for a typical fleet.
        if let companyId = CompanySession.shared.currentCompanyId {
            group.enter()
            let routesRef = Firestore.firestore()
                .collection("companies").document(companyId).collection("routes")
            routesRef.getDocuments { snapshot, _ in
                for doc in snapshot?.documents ?? [] where doc.documentID != currentRouteId {
                    let routeName = (doc.data()["name"] as? String) ?? "Unnamed route"
                    group.enter()
                    doc.reference.collection("stops").getDocuments { stopsSnap, _ in
                        lock.lock()
                        for stopDoc in stopsSnap?.documents ?? [] {
                            let data = stopDoc.data()
                            if let cid = data["customerId"] as? String, !cid.isEmpty {
                                byCustomer[cid, default: []].append(routeName)
                            } else if let address = data["address"] as? String, !address.isEmpty {
                                byAddress[Self.addressKey(address), default: []].append(routeName)
                            }
                        }
                        lock.unlock()
                        group.leave()
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            customers = fetchedCustomers
            routesByCustomer = byCustomer
            routesByAddress = byAddress
            isLoading = false
        }
    }

    // MARK: - Helpers

    /// "731 Exceller Cir, Newmarket, ON, Canada" -> "731 exceller cir"
    static func addressKey(_ address: String) -> String {
        address.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    static func addedLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Added today" }
        if cal.isDateInYesterday(date) { return "Added yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return "Added " + f.string(from: date)
    }
}
