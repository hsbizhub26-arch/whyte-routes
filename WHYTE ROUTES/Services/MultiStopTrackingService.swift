import Foundation
import CoreLocation
import FirebaseFirestore

/// Handles driver progress across multiple stops, timing, and Firestore updates.
final class MultiStopTrackingService: ObservableObject {

    static let shared = MultiStopTrackingService()
    private init() {}

    @Published var currentIndex: Int = 0
    @Published var timeSpentAtCurrentStop: TimeInterval = 0

    private var timer: Timer?
    private let db = Firestore.firestore()

    // MARK: - Start the stopwatch
    func startStopwatch() {
        timer?.invalidate()
        timeSpentAtCurrentStop = 0

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.timeSpentAtCurrentStop += 1
        }
    }

    // MARK: - Stop stopwatch
    func stopStopwatch() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Advance to next stop
    func advanceToNextStop(stops: [Stop]) {

        stopStopwatch()

        if currentIndex < stops.count - 1 {
            currentIndex += 1
        }

        startStopwatch()
    }

    // MARK: - Update Firestore (mark stop complete)
    func markStopCompleted(routeId: String, stopId: String) {
        db.collection("routes")
            .document(routeId)
            .collection("stops")
            .document(stopId)
            .updateData(["isCompleted": true])
    }

    // MARK: - Assign driver to all stops IN ROUTE
    func assignDriverToStops(routeId: String, driverId: String) {

        let ref = db.collection("routes")
                     .document(routeId)
                     .collection("stops")

        ref.getDocuments { snap, error in
            guard let docs = snap?.documents else { return }

            for doc in docs {
                doc.reference.updateData([
                    "driverId": driverId
                ])
            }
        }
    }
}
