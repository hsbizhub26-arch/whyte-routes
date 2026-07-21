import Foundation
import Combine

@MainActor
final class TimerService: ObservableObject {

    static let shared = TimerService()
    private init() {}

    @Published var seconds: Int = 0
    private var timer: Timer?

    func start() {
        // Stop existing timer
        timer?.invalidate()
        seconds = 0

        // Start new timer
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                self.seconds += 1
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
