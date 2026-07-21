//
//  DriverNextStopController.swift
//  WHYTE ROUTES
//

import Foundation

@MainActor
final class DriverNextStopController: ObservableObject {

    static let shared = DriverNextStopController()
    private init() {}

    private let session = DriverSession.shared

    // MARK: - The next stop
    var nextStop: Stop? {
        session.activeStops.first { !$0.completed }
    }

    // MARK: - All remaining stops
    var remainingStops: [Stop] {
        session.activeStops.filter { !$0.completed }
    }

    // MARK: - Completed count
    var completedCount: Int {
        session.activeStops.filter { $0.completed }.count
    }

    // MARK: - Total count
    var totalCount: Int {
        session.activeStops.count
    }

    // MARK: - Complete current stop
    func complete(stop: Stop) {
        session.completeStop(stop)
    }
}
