import Foundation

// B9: invoice DRAFTS from completed visits, for the owner to check and
// then bill in HSLedger (or anywhere else).
//
// Drafts only: nothing is charged, sent, or saved to the server. No tax
// is applied here - HSLedger's invoice editor applies the right
// HST/GST when the real invoice is made. Pure (Foundation only) so the
// grouping and money maths are testable.

struct InvoiceVisit: Equatable {
    let customerId: String?
    let customerName: String
    let address: String
    let serviceDate: String   // yyyy-MM-dd
}

struct InvoiceLine: Equatable {
    let date: String
    let description: String
    let quantity: Int
    let unitPriceCents: Int
    var totalCents: Int { quantity * unitPriceCents }
}

struct InvoiceDraft: Identifiable, Equatable {
    var id: String { customerKey }
    let customerKey: String
    let customerName: String
    let address: String
    let lines: [InvoiceLine]
    var visits: Int { lines.reduce(0) { $0 + $1.quantity } }
    var subtotalCents: Int { lines.reduce(0) { $0 + $1.totalCents } }
}

enum InvoiceDraftBuilder {

    /// One draft per customer; one line per service date (two visits on
    /// the same date - a re-clear - become quantity 2). Visits without
    /// a customer record are grouped by address so nothing is dropped.
    static func drafts(visits: [InvoiceVisit], serviceName: String,
                       rateCents: (String) -> Int) -> [InvoiceDraft] {
        let grouped = Dictionary(grouping: visits) { v in v.customerId ?? "addr:\(v.address.lowercased())" }
        return grouped.map { key, vs in
            let rate = rateCents(key)
            let byDate = Dictionary(grouping: vs, by: \.serviceDate)
            let lines = byDate.keys.sorted().map { date in
                InvoiceLine(date: date, description: "\(serviceName) - \(prettyDate(date))",
                            quantity: byDate[date]!.count, unitPriceCents: rate)
            }
            let latest = vs.max { $0.serviceDate < $1.serviceDate }!
            return InvoiceDraft(customerKey: key, customerName: latest.customerName,
                                address: latest.address, lines: lines)
        }
        .sorted { $0.customerName.localizedCaseInsensitiveCompare($1.customerName) == .orderedAscending }
    }

    /// CSV laid out like HSLedger's invoice editor (customer, date, line
    /// description, quantity, unit price) so each line can be entered or
    /// imported as-is. RFC 4180 quoting; amounts in dollars, 2 decimals.
    static func csv(_ drafts: [InvoiceDraft], invoiceDate: String) -> String {
        var out = "Customer,Service address,Invoice date,Line description,Quantity,Unit price,Line total\n"
        for d in drafts {
            for l in d.lines {
                out += [d.customerName, d.address, invoiceDate, l.description, String(l.quantity),
                        dollars(l.unitPriceCents), dollars(l.totalCents)].map(quote).joined(separator: ",") + "\n"
            }
        }
        return out
    }

    static func dollars(_ cents: Int) -> String {
        String(format: "%@%d.%02d", cents < 0 ? "-" : "", abs(cents) / 100, abs(cents) % 100)
    }

    /// "$1,234.50" for display.
    static func money(_ cents: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "CAD"
        f.locale = Locale(identifier: "en_CA")
        return f.string(from: NSNumber(value: Double(cents) / 100)) ?? "$" + dollars(cents)
    }

    /// Parses "45", "45.5", "$45.50" -> cents. Nil for anything else.
    static func cents(from text: String) -> Int? {
        let s = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let d = Decimal(string: s), d >= 0, d < 1_000_000 else { return nil }
        var v = d * 100
        var r = Decimal()
        NSDecimalRound(&r, &v, 0, .plain)
        return NSDecimalNumber(decimal: r).intValue
    }

    private static func quote(_ s: String) -> String {
        // Also neutralise spreadsheet formula injection (= + - @ first).
        var t = s
        if let f = t.first, "=+-@".contains(f) { t = "'" + t }
        return t.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : t
    }

    private static func prettyDate(_ key: String) -> String {
        let p = DateFormatter(); p.locale = Locale(identifier: "en_US_POSIX"); p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: key) else { return key }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_CA"); f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }
}
