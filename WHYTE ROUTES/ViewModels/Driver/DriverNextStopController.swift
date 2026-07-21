//
//  DriverNextStopController.swift
//  WHYTE ROUTES
//

import Foundation
import Combine

@MainActor
final class DriverNextStopController: ObservableObject {

    static let shared = DriverNextStopController()
    private init() {}

    private let session = DriverSession.shared

    // MARK: - The next stop
    var nextStop: Stop? {
        session.activeStops.first { !$0.isCompleted }
    }

    // MARK: - All remaining stops
    var remainingStops: [Stop] {
        session.activeStops.filter { !$0.isCompleted }
    }

    // MARK: - Completed count
    var completedCount: Int {
        session.activeStops.filter { $0.isCompleted }.count
    }

    // MARK: - Total count
    var totalCount: Int {
        session.activeStops.count
    }

    // MARK: - Complete current stop
    func complete(stop: Stop) {
        session.completeStop(stop)
    }

    // MARK: - Force a UI refresh (called on screen appear)
    func updateNextStop() {
        objectWillChange.send()
    }
}
