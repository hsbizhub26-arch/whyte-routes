import Foundation

// B5: Season Log - one bar per night worked, with how much snow fell.
//
// Pure (Foundation only) so the night-grouping and snowfall rules can be
// tested without Firebase. SeasonLogRepository feeds it.
//
// Rules:
//  - A "night" is the company-local date of (shift start - 6 h): a run
//    that starts at 2 AM belongs to the evening before; an 8 AM job is
//    that day. Overnight storms stay one bar.
//  - Snowfall: an owner-entered value wins and is labelled so. Otherwise
//    the drivers' End Shift answers - if drivers differ, the highest is
//    shown (the crew that saw the most snow) and the spread is kept.
//  - A night with shifts but no snowfall answer still gets a bar
//    position, drawn as "not recorded" - never guessed.

struct SeasonShiftInput: Equatable {
    let driverId: String
    let driverName: String
    let startedAt: Date
    let endedAt: Date?
    let snowfallCm: Int?
}

struct SeasonVisitInput: Equatable {
    let customerId: String?
    let customerName: String?
    let completedAt: Date
}

struct SeasonOverride: Equatable {
    let cm: Int
    let enteredAt: Date?
}

struct SeasonNight: Identifiable, Equatable {
    var id: String { night }
    /// yyyy-MM-dd, company-local.
    let night: String
    let snowfallCm: Int?
    let source: Source
    /// Every driver's own answer, for the detail card.
    let driverAnswers: [Int]
    let crewHours: Double
    let firstStart: Date
    let lastEnd: Date?
    let drivers: [String]
    let stopsCompleted: Int

    enum Source: String, Equatable { case owner, drivers, notRecorded }
}

struct SeasonCustomerCount: Identifiable, Equatable {
    var id: String { customerId }
    let customerId: String
    let name: String
    let visits: Int
}

enum SeasonLogBuilder {

    /// Season = Oct 1 to Sep 30, covering snow (Oct-Apr) and grass
    /// (Apr-Nov) under one season label like "2026-2027".
    static func seasonStart(containing date: Date, timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month], from: date)
        let year = (c.month ?? 1) >= 10 ? (c.year ?? 2000) : (c.year ?? 2000) - 1
        return cal.date(from: DateComponents(year: year, month: 10, day: 1))!
    }

    static func seasonLabel(start: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let y = cal.component(.year, from: start)
        return "\(y)-\(y + 1)"
    }

    /// Whether to offer the snowfall question at End Shift at all:
    /// Oct 15 - Apr 30. A July landscaping crew is never asked about snow.
    static func isSnowSeason(_ date: Date, timeZone: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let m = cal.component(.month, from: date), d = cal.component(.day, from: date)
        return m >= 11 || m <= 4 || (m == 10 && d >= 15)
    }

    static func nightKey(for start: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: start.addingTimeInterval(-6 * 3600))
    }

    static func nights(shifts: [SeasonShiftInput], visits: [SeasonVisitInput],
                       overrides: [String: SeasonOverride], timeZone: TimeZone) -> [SeasonNight] {
        let byNight = Dictionary(grouping: shifts) { nightKey(for: $0.startedAt, timeZone: timeZone) }
        return byNight.keys.sorted().map { key in
            let group = byNight[key]!
            let answers = group.compactMap(\.snowfallCm).filter { $0 >= 0 }
            let first = group.map(\.startedAt).min()!
            let ends = group.compactMap(\.endedAt)
            let last = ends.max()
            let hours = group.reduce(0.0) { sum, s in
                guard let e = s.endedAt else { return sum }
                return sum + max(0, e.timeIntervalSince(s.startedAt)) / 3600
            }
            // Stops done = completed visits inside this night's working
            // window (first start .. last end, or +12 h if still open).
            let windowEnd = last ?? first.addingTimeInterval(12 * 3600)
            let stops = visits.filter { $0.completedAt >= first && $0.completedAt <= windowEnd }.count

            let snow: Int?
            let source: SeasonNight.Source
            if let o = overrides[key] { snow = o.cm; source = .owner }
            else if let maxCm = answers.max() { snow = maxCm; source = .drivers }
            else { snow = nil; source = .notRecorded }

            return SeasonNight(night: key, snowfallCm: snow, source: source, driverAnswers: answers.sorted(),
                               crewHours: hours, firstStart: first, lastEnd: last,
                               drivers: Array(Set(group.map(\.driverName))).sorted(),
                               stopsCompleted: stops)
        }
    }

    static func customerCounts(_ visits: [SeasonVisitInput]) -> [SeasonCustomerCount] {
        let grouped = Dictionary(grouping: visits.filter { $0.customerId != nil }) { $0.customerId! }
        return grouped.map { id, vs in
            SeasonCustomerCount(customerId: id, name: vs.compactMap(\.customerName).last ?? "Customer", visits: vs.count)
        }
        .sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.name < $1.name }
    }
}
