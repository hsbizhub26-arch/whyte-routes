import SwiftUI
import FirebaseFirestore

/// B9: invoice drafts from completed visits, plus the HSLedger bridge.
///
/// DRAFTS ONLY. Nothing here charges, sends or saves anything: it reads
/// completed visits (serviceHistory), multiplies by the rate the owner
/// types, and lets them export a CSV laid out like HSLedger's invoice
/// editor or open HSLedger's New Invoice page to bill properly (with
/// tax) there. The default rate is remembered on this phone only.
struct InvoiceDraftsView: View {
    @Environment(\.dismiss) private var dismiss

    enum Period: String, CaseIterable, Identifiable {
        case thisMonth = "This month", lastMonth = "Last month", season = "This season"
        var id: String { rawValue }
    }

    @State private var period: Period = .thisMonth
    @AppStorage("invoice.defaultRate") private var defaultRateText = ""
    @AppStorage("invoice.serviceName") private var serviceName = "Snow clearing"
    @State private var overrides: [String: String] = [:]
    @State private var excluded: Set<String> = []
    @State private var visits: [InvoiceVisit] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var csvURL: URL?
    /// Phase 6: customerId -> contract label, for customers on a prepaid
    /// seasonal contract. They start switched off (the owner can still
    /// switch one back on).
    @State private var contracts: [String: String] = [:]

    private static let hsledgerNewInvoice = URL(string: "https://ledger.hsbizhub.com/app/business/invoices/new")!

    private var defaultCents: Int { InvoiceDraftBuilder.cents(from: defaultRateText) ?? 0 }

    private var drafts: [InvoiceDraft] {
        InvoiceDraftBuilder.drafts(visits: visits, serviceName: serviceName.isEmpty ? "Service" : serviceName) { key in
            overrides[key].flatMap(InvoiceDraftBuilder.cents(from:)) ?? defaultCents
        }
    }
    private var included: [InvoiceDraft] { drafts.filter { !excluded.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Rate per visit")
                        Spacer()
                        TextField("$0.00", text: $defaultRateText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                    HStack {
                        Text("Line name")
                        Spacer()
                        TextField("Snow clearing", text: $serviceName)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("Drafts only - nothing is charged or sent. Tax is added when you make the real invoice in HSLedger. Seasonal (prepaid) customers can be switched off below.")
                }

                if isLoading {
                    Section { HStack { ProgressView(); Text("Loading visits…").foregroundColor(.secondary) } }
                } else if let loadError {
                    Section { Text(loadError).foregroundColor(.orange) }
                } else if drafts.isEmpty {
                    Section { Text("No completed visits in this period.").foregroundColor(.secondary) }
                } else {
                    Section {
                        HStack {
                            let totalVisits = included.reduce(0) { $0 + $1.visits }
                            Text("\(included.count) draft\(included.count == 1 ? "" : "s") · \(totalVisits) visit\(totalVisits == 1 ? "" : "s")")
                            Spacer()
                            Text(InvoiceDraftBuilder.money(included.reduce(0) { $0 + $1.subtotalCents }))
                                .bold().foregroundColor(WRTheme.gold)
                        }
                        if defaultCents == 0 && overrides.isEmpty {
                            Text("Enter a rate per visit above to see amounts.").font(.caption).foregroundColor(.orange)
                        }
                    } header: { Text("Before tax") }

                    Section("Customers") {
                        ForEach(drafts) { d in draftRow(d) }
                    }

                    Section {
                        if let csvURL {
                            ShareLink(item: csvURL) {
                                Label("Export drafts (CSV for HSLedger)", systemImage: "square.and.arrow.up")
                            }
                        }
                        Link(destination: Self.hsledgerNewInvoice) {
                            Label("Open HSLedger · New invoice", systemImage: "arrow.up.right.square")
                        }
                    } footer: {
                        Text("The CSV has one row per invoice line: customer, address, date, description, quantity, unit price. HSLedger opens in your browser.")
                    }
                }
            }
            .navigationTitle("Invoice Drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: period) { await load() }
            .onChange(of: included) { _, _ in writeCSV() }
            .onChange(of: defaultRateText) { _, _ in writeCSV() }
        }
    }

    private func draftRow(_ d: InvoiceDraft) -> some View {
        let on = !excluded.contains(d.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    if on { excluded.insert(d.id) } else { excluded.remove(d.id) }
                } label: {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundColor(on ? WRTheme.gold : .secondary)
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(on ? "Included" : "Excluded")
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.customerName).font(.headline)
                    Text("\(d.visits) visit\(d.visits == 1 ? "" : "s") · \(d.address)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                    if let label = contracts[d.id] {
                        Label("Seasonal contract: \(label)", systemImage: "doc.text")
                            .font(.caption.weight(.semibold)).foregroundColor(WRTheme.gold)
                    }
                }
                Spacer()
                Text(InvoiceDraftBuilder.money(d.subtotalCents)).bold()
            }
            if on {
                HStack {
                    Text("Rate for this customer").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    TextField(defaultRateText.isEmpty ? "$0.00" : defaultRateText, text: Binding(
                        get: { overrides[d.id] ?? "" },
                        set: { overrides[d.id] = $0.isEmpty ? nil : $0 }
                    ))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
                    .font(.caption)
                }
            }
        }
        .opacity(on ? 1 : 0.55)
    }

    private func range() -> (String, String) {
        let tz = TimeZone(identifier: CompanySession.shared.currentCompany?.timeZoneIdentifier ?? "America/Toronto") ?? .current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = Date()
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd"
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        switch period {
        case .thisMonth: return (f.string(from: monthStart), f.string(from: now))
        case .lastMonth:
            let lastStart = cal.date(byAdding: .month, value: -1, to: monthStart)!
            return (f.string(from: lastStart), f.string(from: monthStart.addingTimeInterval(-1)))
        case .season:
            return (f.string(from: SeasonLogBuilder.seasonStart(containing: now, timeZone: tz)), f.string(from: now))
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        guard let companyId = CompanySession.shared.currentCompanyId else { isLoading = false; return }
        let (from, to) = range()
        do {
            let snap = try await Firestore.firestore().collection("companies").document(companyId)
                .collection("serviceHistory")
                .whereField("serviceDate", isGreaterThanOrEqualTo: from)
                .whereField("serviceDate", isLessThanOrEqualTo: to)
                .getDocuments()
            visits = snap.documents.compactMap { doc in
                let d = doc.data()
                guard (d["outcome"] as? String) == "completed", let date = d["serviceDate"] as? String else { return nil }
                return InvoiceVisit(customerId: d["customerId"] as? String,
                                    customerName: (d["customerName"] as? String) ?? (d["address"] as? String) ?? "Customer",
                                    address: (d["address"] as? String) ?? "",
                                    serviceDate: date)
            }
        } catch {
            loadError = "Couldn't load visits: \(error.localizedDescription)"
        }
        // Contract customers: label them and start them excluded. Only
        // added to `excluded` the first time they're seen, so an owner who
        // switched one back on keeps that choice when the period changes.
        let customers: [Customer] = await withCheckedContinuation { c in
            CustomerRepository().fetchCustomers { result in
                c.resume(returning: (try? result.get()) ?? [])
            }
        }
        var found: [String: String] = [:]
        for cust in customers where cust.hasContract { found[cust.id] = cust.contractLabel }
        for id in found.keys where contracts[id] == nil { excluded.insert(id) }
        contracts = found
        isLoading = false
        writeCSV()
    }

    private func writeCSV() {
        guard !included.isEmpty else { csvURL = nil; return }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let text = InvoiceDraftBuilder.csv(included, invoiceDate: f.string(from: Date()))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Invoice drafts \(period.rawValue).csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            csvURL = url
        } catch {
            csvURL = nil
        }
    }
}
