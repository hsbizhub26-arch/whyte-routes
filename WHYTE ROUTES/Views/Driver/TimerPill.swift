import SwiftUI

struct TimerPill: View {

    @ObservedObject var timer = TimerService.shared

    var body: some View {
        Text("Time: \(timer.seconds)s")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.85))
            .foregroundColor(.white)
            .clipShape(Capsule())
            .shadow(color: .yellow.opacity(0.3), radius: 8, y: 4)
            .onAppear { timer.start() }
            .onDisappear { timer.stop() }
    }
}
