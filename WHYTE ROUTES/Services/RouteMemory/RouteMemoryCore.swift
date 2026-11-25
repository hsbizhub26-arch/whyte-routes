import Foundation

// MARK: - Route Memory logic (Foundation only)
//
// Predictions, run summary, flag wording, the will-this-flag check that
// drives the driver's reason chips, the Shift History row and the CSV.
// Pure functions, no Firebase: they run offline on the phone from the
// cached property stats. Mirrors functions/routeMemoryCore.js - the
// route-memory-tests suite runs both on the same inputs and fails on any
// difference.

enum SizeTier: String, CaseIterable {
    case single, double, triple, unknown
}

struct PropertyStats {
    var visitCount: Int
    var avgDurationSec: Double?
}

struct Prediction {
    var sec: Double
    var basis: String
    var fromHistory: Bool
}

/// The fields of a serviceHistory visit the display logic needs.
struct VisitRecord {
    var address: String = ""
    var driverName: String = ""
    var outcome: String = "in_progress"
    var correctedOutcome: String? = nil
    var source: String? = nil
    var enRouteAt: Date? = nil
    var arrivedAt: Date? = nil
    var completedAt: Date? = nil
    var correctedArrivedAt: Date? = nil
    var correctedCompletedAt: Date? = nil
    var createdAt: Date? = nil
    var reasonCode: String? = nil
    var reasonText: String? = nil
    var flagged: Bool? = nil
    var flagRatio: Double? = nil
}

struct RunRow {
    var stopsCompleted: Int
    var stopsSkipped: Int
    var totalTimeSec: Int?
    var avgPerStopSec: Double?
}

enum RouteMemoryCore {

    static let reasonLabels: [String: String] = [
        "deep_snow": "Deep snow",
        "blocked_driveway": "Blocked driveway",
        "car_in_way": "Car in the way",
        "equipment_issue": "Equipment issue",
        "first_visit": "First visit",
        "other": "Other"
    ]
    /// Chip order on the driver's screen.
    static let reasonOrder = ["deep_snow", "blocked_driveway", "car_in_way", "equipment_issue", "first_visit", "other"]

    // MARK: Status / duration

    static func effectiveStatus(_ v: VisitRecord, now: Date) -> String {
        let o = v.correctedOutcome ?? v.outcome
        guard o == "in_progress" else { return o }
        if let last = v.arrivedAt ?? v.enRouteAt ?? v.createdAt,
           now.timeIntervalSince(last) >= Double(RouteMemory.OPEN_VISIT_MAX_AGE_SEC) {
            return "incomplete"
        }
        return "in_progress"
    }

    /// Whole elapsed seconds (UTC subtraction - daylight saving can't skew it).
    static func durationSec(_ v: VisitRecord) -> Double? {
        guard let a = v.correctedArrivedAt ?? v.arrivedAt,
              let c = v.correctedCompletedAt ?? v.completedAt, c > a else { return nil }
        return c.timeIntervalSince(a)
    }

    // MARK: Prediction

    static func defaultSec(_ tier: SizeTier?) -> Double {
        switch tier {
        case .single: return RouteMemory.DEFAULT_SINGLE_SEC
        case .double: return RouteMemory.DEFAULT_DOUBLE_SEC
        case .triple: return RouteMemory.DEFAULT_TRIPLE_SEC
        default: return RouteMemory.DEFAULT_UNKNOWN_SEC
        }
    }

    /// The label states the number of visits actually used: min(count, 5).
    static func predict(stats: PropertyStats?, tier: SizeTier?, snow: Bool) -> Prediction {
        let factor = snow ? RouteMemory.SNOW_FACTOR : 1
        if let s = stats, s.visitCount >= RouteMemory.MIN_VISITS_FOR_AVERAGE, let avg = s.avgDurationSec {
            return Prediction(sec: avg * factor,
                              basis: "avg of last \(min(s.visitCount, RouteMemory.STATS_WINDOW)) visits",
                              fromHistory: true)
        }
        return Prediction(sec: defaultSec(tier) * factor, basis: "estimate", fromHistory: false)
    }

    // MARK: Flags

    /// "2.00x usual" - two decimals are display only.
    static func formatFlagTag(_ ratio: Double) -> String {
        String(format: "%.2fx usual", ratio)
    }

    /// Would a visit that has run `elapsedSec` flag against this history?
    /// Same rule the server applies at completion; used to decide when to
    /// offer the reason chips. Informational only - never blocks Complete.
    static func willFlag(elapsedSec: Double, avgSec: Double?, visitCount: Int) -> Bool {
        guard visitCount >= RouteMemory.MIN_VISITS_FOR_FLAG, let avg = avgSec, avg > 0 else { return false }
        return elapsedSec / avg >= RouteMemory.FLAG_RATIO && elapsedSec - avg > RouteMemory.FLAG_MIN_OVER_SEC
    }

    // MARK: Time formatting (company time zone)

    private static func formatter(_ pattern: String, tz: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz) ?? .current
        f.dateFormat = pattern
        return f
    }
    static func formatLocalTime(_ d: Date, tz: String) -> String { formatter("h:mm a", tz: tz).string(from: d) }
    static func formatLocalDateTime(_ d: Date, tz: String) -> String { formatter("yyyy-MM-dd HH:mm", tz: tz).string(from: d) }
    static func formatMinSec(_ sec: Double) -> String {
        let s = Int(sec.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
    static func formatWork(_ sec: Double) -> String {
        let mins = Int((sec / 60).rounded())
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hrs" : "\(h) hrs \(m) min"
    }

    // MARK: Run setup summary

    /// finish = start + total (an absolute instant, so right across a DST
    /// change); only the display is in the company's zone. No drive ETAs
    /// exist, so the text says "service time only" - never presented as
    /// total route time.
    static func runSummary(stopCount: Int, totalServiceSec: Double, start: Date, tz: String,
                           driveSec: Double? = nil) -> (finish: Date, text: String) {
        let total = totalServiceSec + (driveSec ?? 0)
        let finish = start.addingTimeInterval(total)
        let label = driveSec != nil ? "including drive time" : "service time only"
        return (finish, "\(stopCount) stops · about \(formatWork(total)) of work (\(label)) · estimated finish around \(formatLocalTime(finish, tz: tz))")
    }

    // MARK: Shift History row

    static func runRow(startedAt: Date, endedAt: Date?, visits: [VisitRecord], now: Date) -> RunRow {
        let end = endedAt ?? now
        let total = max(0, Int((end.timeIntervalSince(startedAt)).rounded()))
        var done = 0, skipped = 0
        for v in visits {
            switch effectiveStatus(v, now: now) {
            case "completed": done += 1
            case "skipped": skipped += 1
            default: break
            }
        }
        return RunRow(stopsCompleted: done, stopsSkipped: skipped, totalTimeSec: total,
                      avgPerStopSec: done > 0 ? Double(total) / Double(done) : nil)
    }

    // MARK: Reason + CSV

    static func reasonLabel(_ v: VisitRecord) -> String {
        guard let code = v.reasonCode else { return "" }
        if code == "other" { return (v.reasonText?.isEmpty == false ? v.reasonText! : "Other") }
        return reasonLabels[code] ?? ""
    }

    /// RFC 4180 quoting, plus a leading ' on cells a spreadsheet would run as a formula.
    static func csvCell(_ s: String) -> String {
        var t = s
        if let first = t.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { t = "'" + t }
        if t.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return t
    }

    static func buildRunCsv(_ rows: [VisitRecord], tz: String, now: Date) -> String {
        var out = ["Address,Driver,Start,Complete,Duration,Status,Flagged,Reason"]
        for v in rows {
            let a = v.correctedArrivedAt ?? v.arrivedAt
            let c = v.correctedCompletedAt ?? v.completedAt
            let dur = durationSec(v)
            let cells: [String] = [
                v.address, v.driverName,
                a.map { formatLocalDateTime($0, tz: tz) } ?? "",
                c.map { formatLocalDateTime($0, tz: tz) } ?? "",
                dur.map { formatMinSec($0) } ?? "",
                effectiveStatus(v, now: now),
                v.flagged == true ? "Yes" : "No",
                reasonLabel(v)
            ]
            out.append(cells.map(csvCell).joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
