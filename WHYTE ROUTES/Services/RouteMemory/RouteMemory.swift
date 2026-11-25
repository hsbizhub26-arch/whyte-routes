import Foundation

// MARK: - Route Memory constants
//
// ONE place for every number the feature uses on the phone. They are
// mirrored once in functions/routeMemoryConstants.json (the Cloud
// Functions' copy); route-memory-tests fails if the two ever differ.
enum RouteMemory {
    static let DEFAULT_SINGLE_SEC: Double = 360
    static let DEFAULT_DOUBLE_SEC: Double = 540
    static let DEFAULT_TRIPLE_SEC: Double = 720
    static let DEFAULT_UNKNOWN_SEC: Double = 540
    /// "Heavy snow tonight": scales THAT run's predictions only. Never
    /// applied to stored averages.
    static let SNOW_FACTOR: Double = 1.3
    /// A visit flags when it took >= FLAG_RATIO x the usual AND ran more
    /// than FLAG_MIN_OVER_SEC over it (strictly more).
    static let FLAG_RATIO: Double = 1.5
    static let FLAG_MIN_OVER_SEC: Double = 120
    /// Averages use the last STATS_WINDOW completed visits.
    static let STATS_WINDOW: Int = 5
    static let MIN_VISITS_FOR_AVERAGE: Int = 2
    static let MIN_VISITS_FOR_FLAG: Int = 2
    /// Same 18-hour cutoff as ServiceHistoryRepository.openVisitMaxAge.
    static let OPEN_VISIT_MAX_AGE_SEC: Int = 64800
    static let REASON_OTHER_MAX_CHARS: Int = 80
}
