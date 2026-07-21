import Foundation

final class StopsService {

    private let repo: StopsRepository = FirestoreStopsRepository()

    func reorder(stops: inout [Stop]) {
        for i in 0..<stops.count {
            stops[i].order = i
        }
    }

    func markCompleted(_ stop: Stop, in route: Route) {
        // You insert the Firestore update here later.
    }
}
