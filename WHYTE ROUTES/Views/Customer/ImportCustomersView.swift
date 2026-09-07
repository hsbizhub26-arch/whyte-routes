import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import FirebaseFirestore

// Bulk customer import from a CSV file.
//
// The #1 reason an operator refuses to switch platforms is retyping
// their book. Hand-entering 200 driveways on a phone is three hours of
// the owner's own unpaid time, spent BEFORE they have seen any value -
// so it never happens, and the trial dies there.
//
// Built in-app rather than as a web page for one decisive reason:
// Customer.latitude/longitude are NON-OPTIONAL, and the only free
// geocoder available to this project is on-device CoreLocation. A web
// importer would force a paid geocoding API and a whole new login
// surface. Here, the owner is already signed in and the rules already
// authorise the write.
//
// THE INVARIANT: never write a customer without real coordinates.
//   - A coordinate-less customer is silently DROPPED by the decoder,
//     so the dispatcher would import 200 rows and see zero, with
//     nothing on screen explaining why.
//   - Writing 0,0 instead is worse: it decodes fine, then poisons
//     everything downstream. Route optimization treats it as a real
//     anchor in the Gulf of Guinea and wrecks the ordering, and the
//     40m arrival geofence never fires, so that customer's completion
//     text never sends.
// Failed rows stay in the review list and are never persisted.
struct ImportCustomersView: View {

    /// Existing customers, used to bias ambiguous addresses toward the
    /// area this company actually works in.
    let existing: [Customer]
    var onFinished: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var access = FeatureAccessManager.shared

    @State private var rows: [ImportRow] = []
    @State private var stage: Stage = .pickFile
    @State private var geocodedCount = 0
    @State private var totalToGeocode = 0
    @State private var showFileImporter = false
    @State private var errorMessage: String?
    @State private var savedCount = 0

    private enum Stage { case pickFile, geocoding, review, saving, done }

    var body: some View {
        NavigationStack {
            ZStack {
                WRTheme.gradient.ignoresSafeArea()
                content.padding()
            }
            .navigationTitle("Import Customers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                allowsMultipleSelection: false
            ) { result in
                handlePickedFile(result)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .pickFile:   pickFileStage
        case .geocoding:  geocodingStage
        case .review:     reviewStage
        case .saving:     ProgressView("Saving customers…").tint(WRTheme.gold)
        case .done:       doneStage
        }
    }

    // MARK: - Stages

    private var pickFileStage: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.system(size: 44))
                .foregroundColor(WRTheme.gold)

            Text("Import your customer list")
                .font(.headline)
                .foregroundColor(.white)

            Text("Drop your spreadsheet into Files or iCloud Drive, then pick it here. Addresses are looked up automatically - you review everything before anything is saved.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 4) {
                Text("Columns").font(.caption.bold()).foregroundColor(WRTheme.gold)
                Text("name, address, phone, email, notes")
                    .font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.8))
                Text("A header row is detected automatically. Only name and address are required.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.black.opacity(0.25))
            .cornerRadius(12)

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                errorMessage = nil
                showFileImporter = true
            } label: {
                Label("Choose CSV file", systemImage: "doc.badge.plus")
                    .font(.headline).foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding()
                    .background(WRTheme.gold).cornerRadius(14)
            }
            Spacer()
        }
    }

    private var geocodingStage: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: Double(geocodedCount), total: Double(max(1, totalToGeocode)))
                .tint(WRTheme.gold)
            Text("Looking up \(geocodedCount) of \(totalToGeocode) addresses…")
                .font(.subheadline).foregroundColor(.white)
            // Said plainly so a dispatcher does not think it has hung.
            Text("Address lookup is rate-limited by the system, so this takes about a second per row. You can leave this screen open.")
                .font(.caption).foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var reviewStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            let ok = rows.filter { $0.isImportable }.count
            let bad = rows.count - ok

            HStack(spacing: 14) {
                summaryChip(count: ok, label: "ready", color: .green)
                if bad > 0 { summaryChip(count: bad, label: "need attention", color: .orange) }
            }

            if let capped = capacityWarning(readyCount: ok) {
                Text(capped).font(.footnote).foregroundColor(.orange)
            }

            List {
                ForEach($rows) { $row in
                    ImportRowCell(row: $row)
                        .listRowBackground(Color.black.opacity(0.25))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Button {
                Task { await save() }
            } label: {
                Text(ok == 0 ? "Nothing to import" : "Import \(min(ok, allowedToSave)) customer\(min(ok, allowedToSave) == 1 ? "" : "s")")
                    .font(.headline).foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding()
                    .background(ok == 0 ? Color.gray : WRTheme.gold)
                    .cornerRadius(14)
            }
            .disabled(ok == 0)
        }
    }

    private var doneStage: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48)).foregroundColor(.green)
            Text("Imported \(savedCount) customer\(savedCount == 1 ? "" : "s")")
                .font(.headline).foregroundColor(.white)
            let skipped = rows.count - savedCount
            if skipped > 0 {
                Text("\(skipped) row\(skipped == 1 ? "" : "s") skipped - nothing was saved for those.")
                    .font(.subheadline).foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            Button("Done") { onFinished(savedCount); dismiss() }
                .font(.headline).foregroundColor(.black)
                .frame(maxWidth: .infinity).padding()
                .background(WRTheme.gold).cornerRadius(14)
            Spacer()
        }
    }

    private func summaryChip(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count) \(label)").font(.subheadline).foregroundColor(.white)
        }
    }

    // MARK: - Plan capacity

    /// The importer must not become a second way around the tier cap -
    /// the Add button is already gated, so this is too.
    private var allowedToSave: Int {
        guard let limit = access.customerLimit else { return .max }
        return max(0, limit - existing.count)
    }

    private func capacityWarning(readyCount: Int) -> String? {
        guard let limit = access.customerLimit, readyCount > allowedToSave else { return nil }
        return "Your \(access.tier.displayName) plan holds \(limit) customers and you have \(existing.count). Only the first \(allowedToSave) will be imported - upgrade to import the rest."
    }

    // MARK: - Pipeline

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // A file from Files/iCloud is outside the sandbox until
            // this is called; without it the read fails with a
            // permission error that reads like a corrupt file.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let parsed = CSVCustomerParser.parse(text)
                guard !parsed.isEmpty else {
                    errorMessage = "No rows found. Check the file has a name and address column."
                    return
                }
                rows = parsed
                Task { await geocodeAll() }
            } catch {
                errorMessage = "Couldn't read that file: \(error.localizedDescription)"
            }
        }
    }

    private func geocodeAll() async {
        stage = .geocoding
        totalToGeocode = rows.count
        geocodedCount = 0

        let region = Self.biasRegion(from: existing)
        let geocoder = BatchGeocoder()
        let resolved = await geocoder.resolve(
            addresses: rows.map(\.address),
            near: region
        ) { done, _ in
            Task { @MainActor in geocodedCount = done }
        }

        for r in resolved where r.index < rows.count {
            rows[r.index].coordinate = r.coordinate
            rows[r.index].resolvedAddress = r.normalizedAddress
            rows[r.index].failureReason = r.failureReason
        }
        stage = .review
    }

    /// Centroid of the existing book, so "12 Main St" resolves in the
    /// right province rather than the first Main St on Earth.
    private static func biasRegion(from customers: [Customer]) -> CLCircularRegion? {
        let coords = customers.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            .filter { $0.latitude != 0 || $0.longitude != 0 }
        guard !coords.isEmpty else { return nil }
        let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let lng = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            radius: 60_000, identifier: "import-bias"
        )
    }

    private func save() async {
        stage = .saving
        let importable = rows.filter { $0.isImportable }.prefix(allowedToSave)
        guard !importable.isEmpty, let companyId = CompanySession.shared.currentCompanyId else {
            savedCount = 0; stage = .done; return
        }

        let db = Firestore.firestore()
        let collection = db.collection("companies").document(companyId).collection("customers")
        var written = 0

        // Chunked at 400 - Firestore caps a batch at 500 writes and a
        // real book can exceed that.
        for chunk in Array(importable).chunked(into: 400) {
            let batch = db.batch()
            for row in chunk {
                guard let coordinate = row.coordinate else { continue }
                let customer = Customer(
                    id: UUID().uuidString,
                    name: row.name,
                    address: row.resolvedAddress ?? row.address,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    phone: row.phone.isEmpty ? nil : row.phone,
                    email: row.email.isEmpty ? nil : row.email,
                    notes: row.notes.isEmpty ? nil : row.notes,
                    // Consent is NEVER inferred from a spreadsheet. CASL
                    // requires provable consent, and a column in a CSV is
                    // not that - the owner turns notifications on per
                    // customer, which stamps consentTimestamp properly.
                    notificationsOptIn: false
                )
                batch.setData(customer.toDict(), forDocument: collection.document(customer.id))
                written += 1
            }
            do { try await batch.commit() } catch {
                errorMessage = error.localizedDescription
                written -= chunk.count
            }
        }
        savedCount = max(0, written)
        stage = .done
    }
}

// MARK: - Row

struct ImportRow: Identifiable {
    let id = UUID()
    var name: String
    var address: String
    var phone: String = ""
    var email: String = ""
    var notes: String = ""

    var coordinate: CLLocationCoordinate2D?
    var resolvedAddress: String?
    var failureReason: String?
    var skipped = false

    var isImportable: Bool { coordinate != nil && !skipped && !name.isEmpty }
}

private struct ImportRowCell: View {
    @Binding var row: ImportRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.isImportable ? "checkmark.circle.fill"
                                               : (row.skipped ? "minus.circle" : "exclamationmark.triangle.fill"))
                .foregroundColor(row.isImportable ? .green : (row.skipped ? .gray : .orange))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name.isEmpty ? "(no name)" : row.name)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                Text(row.resolvedAddress ?? row.address)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                if let reason = row.failureReason, !row.skipped {
                    Text(reason).font(.caption2).foregroundColor(.orange)
                }
            }
            Spacer()
            if row.coordinate == nil && !row.skipped {
                Button("Skip") { row.skipped = true }
                    .font(.caption).foregroundColor(WRTheme.gold)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Parser

enum CSVCustomerParser {

    /// Tolerant on purpose: real exported books have quoted commas,
    /// CRLF endings, a BOM, blank trailing lines and inconsistent
    /// header spellings. A parser that rejects any of those hands the
    /// dispatcher back a failure they cannot act on.
    static func parse(_ raw: String) -> [ImportRow] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
                      .replacingOccurrences(of: "\r", with: "\n")
                      .replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return [] }

        var index = 0
        var map: [String: Int] = [:]
        let firstFields = splitLine(lines[0]).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let looksLikeHeader = firstFields.contains { ["name", "customer", "address", "street"].contains($0) }
        if looksLikeHeader {
            for (i, field) in firstFields.enumerated() { map[field] = i }
            index = 1
        }

        func column(_ names: [String], _ fields: [String], fallback: Int?) -> String {
            for n in names {
                if let i = map[n], i < fields.count {
                    return fields[i].trimmingCharacters(in: .whitespaces)
                }
            }
            if let f = fallback, f < fields.count {
                return fields[f].trimmingCharacters(in: .whitespaces)
            }
            return ""
        }

        var out: [ImportRow] = []
        for line in lines[index...] {
            let fields = splitLine(line)
            guard fields.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }

            let name = column(["name", "customer", "customer name", "client"], fields, fallback: looksLikeHeader ? nil : 0)
            let address = column(["address", "street", "service address", "location"], fields, fallback: looksLikeHeader ? nil : 1)
            guard !address.isEmpty else { continue }

            out.append(ImportRow(
                name: name.isEmpty ? address : name,
                address: address,
                phone: column(["phone", "phone number", "mobile", "cell"], fields, fallback: looksLikeHeader ? nil : 2),
                email: column(["email", "e-mail", "email address"], fields, fallback: looksLikeHeader ? nil : 3),
                notes: column(["notes", "note", "instructions", "gate code"], fields, fallback: looksLikeHeader ? nil : 4)
            ))
        }
        return out
    }

    /// Handles quoted fields containing commas and "" escapes - a
    /// naive components(separatedBy:) splits "123 Main St, Unit 4"
    /// into two broken columns, which is the single most common way a
    /// real address file breaks.
    private static func splitLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?

        while let ch = pending ?? iterator.next() {
            pending = nil
            if ch == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" { current.append("\"") } else { inQuotes = false; pending = next }
                } else {
                    inQuotes.toggle()
                }
            } else if ch == ",", !inQuotes {
                fields.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
