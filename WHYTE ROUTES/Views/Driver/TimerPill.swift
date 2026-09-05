import SwiftUI

// Real elapsed time since arrival - stop.arrivedAt is a genuine
// Firestore timestamp (see Stop.enRouteAt/arrivedAt/completedAt),
// not a frontend-only counter. The previous version ticked a bare
// in-memory Timer that reset to 0 on every view appearance and showed
// raw unformatted seconds ("Time: 743s") - it would silently go wrong
// the moment a driver backgrounded the app or reopened this stop, and
// never matched what DriverReportsView computes from the same real
// timestamps. TimelineView just re-renders the formatted duration
// every second; arrivedAt is the only source of truth.
struct TimerPill: View {

    let arrivedAt: Date

    var body: some View {
        TimelineView(.periodic(from: arrivedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(arrivedAt)))
            Text("At property: \(formatted(seconds))")
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.85))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .shadow(color: Color("WRThemeGold").opacity(0.3), radius: 8, y: 4)
        }
    }

    // Rolls over into hours. Without this the minutes field just kept
    // counting: a crew that spent the morning on one commercial lot read
    // "At property: 407:52", which is neither a time anyone recognises
    // nor obviously seven hours. Minutes stay unpadded under an hour so
    // the common case still reads "4:07", and become two digits once
    // there is an hours field in front of them to align against.
    private func formatted(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
