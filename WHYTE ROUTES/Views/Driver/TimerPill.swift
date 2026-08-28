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

    private func formatted(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
