import Foundation
import SwiftUI

/// Phase 2: which season a customer or route belongs to.
///
/// Stored as plain strings ("snow", "grass") so older app builds and the
/// Cloud Functions ignore the field safely. A missing or empty value means
/// BOTH seasons - every record that existed before this field keeps showing
/// in both, so nothing disappears when the season switch arrives.
enum Season: String, CaseIterable, Identifiable {
    case snow
    case grass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .snow: return "Snow"
        case .grass: return "Grass"
        }
    }

    var symbol: String {
        switch self {
        case .snow: return "snowflake"
        case .grass: return "leaf.fill"
        }
    }

    /// Reads a stored value (string or list), dropping anything unknown. Empty = both.
    static func decode(_ any: Any?) -> Set<Season> {
        if let s = any as? String { return Set([Season(rawValue: s)].compactMap { $0 }) }
        let raw = any as? [String] ?? []
        return Set(raw.compactMap(Season.init(rawValue:)))
    }

    /// Stored form, sorted so writes are stable. Both selected = [] (both).
    static func encode(_ set: Set<Season>) -> [String] {
        set.count == Season.allCases.count ? [] : set.map(\.rawValue).sorted()
    }

    /// True when a record tagged `tags` belongs in `season`.
    static func matches(_ tags: Set<Season>, _ season: Season) -> Bool {
        tags.isEmpty || tags.contains(season)
    }
}

/// The season switch: which records the route and customer lists show.
/// "All" is the default, so nothing is hidden until the owner picks one.
/// Saved on this phone (AppStorage key `season.filter`); a company-wide
/// setting would need a Firestore rules change, so that is left for later.
enum SeasonFilter: String, CaseIterable, Identifiable {
    case all, snow, grass
    static let storageKey = "season.filter"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .snow: return "Snow"
        case .grass: return "Grass"
        }
    }
    var season: Season? { Season(rawValue: rawValue) }

    func includes(_ tags: Set<Season>) -> Bool {
        guard let season else { return true }
        return Season.matches(tags, season)
    }
}

struct SeasonSwitch: View {
    @AppStorage(SeasonFilter.storageKey) private var raw = SeasonFilter.all.rawValue

    var body: some View {
        Picker("Season", selection: $raw) {
            ForEach(SeasonFilter.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Season filter")
    }
}

/// Snow / Grass chips used in the customer and route editors. Both lit =
/// both seasons (stored as empty). You can't switch both off - a record
/// always belongs to at least one season.
struct SeasonChips: View {
    @Binding var seasons: Set<Season>

    private var effective: Set<Season> { seasons.isEmpty ? Set(Season.allCases) : seasons }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Season.allCases) { season in
                let on = effective.contains(season)
                Button {
                    var next = effective
                    if on { next.remove(season) } else { next.insert(season) }
                    guard !next.isEmpty else { return }
                    seasons = next.count == Season.allCases.count ? [] : next
                } label: {
                    Label(season.label, systemImage: season.symbol)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(on ? Color.black : Color.secondary)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(season.label) season")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
