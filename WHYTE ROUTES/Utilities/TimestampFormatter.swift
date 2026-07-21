import Foundation

final class TimestampFormatter {
    static let shared = TimestampFormatter()
    private init() {}

    func asTimeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))

        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }

        return "\(seconds / 86400)d ago"
    }
}
