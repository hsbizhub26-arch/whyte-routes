import Foundation

// Company-level navigation preferences. Honest limitation, not
// glossed over: of the three providers NavigationService supports,
// only Google Maps' URL scheme actually accepts avoid-tolls/
// avoid-highways parameters. Apple Maps' and Waze's external launch
// APIs expose no such option - there is no way to force that from
// outside those apps without building a custom navigation engine,
// which was explicitly out of scope. avoidHOV isn't supported by any
// of the three providers' external URL schemes at all. These settings
// are still stored and applied wherever a provider actually honors
// them, and are ready for a future provider (or paid routing API)
// that supports more of them - see NavigationService.
struct NavigationSettings {
    var avoidTolls: Bool
    var avoidHOV: Bool
    var avoidHighways: Bool
    var preferredProvider: String

    // Explicit nonisolated init, not the synthesized memberwise one -
    // the default value NavigationService.MapApp.appleMaps.rawValue
    // resolves through @MainActor NavigationService, which otherwise
    // makes the synthesized init MainActor-isolated too. That's fine
    // for callers already on MainActor, but NavigationService.navigate
    // uses NavigationSettings() as a default parameter value, and
    // default-argument expressions are evaluated in a nonisolated
    // context regardless of the calling function's own isolation -
    // hence the warning this fixes.
    nonisolated init(
        avoidTolls: Bool = true,
        avoidHOV: Bool = true,
        avoidHighways: Bool = false,
        preferredProvider: String = NavigationService.MapApp.appleMaps.rawValue
    ) {
        self.avoidTolls = avoidTolls
        self.avoidHOV = avoidHOV
        self.avoidHighways = avoidHighways
        self.preferredProvider = preferredProvider
    }
}

extension NavigationSettings {
    init(from dict: [String: Any]?) {
        self.avoidTolls = dict?["avoidTolls"] as? Bool ?? true
        self.avoidHOV = dict?["avoidHOV"] as? Bool ?? true
        self.avoidHighways = dict?["avoidHighways"] as? Bool ?? false
        self.preferredProvider = dict?["preferredProvider"] as? String
            ?? NavigationService.MapApp.appleMaps.rawValue
    }

    func toDict() -> [String: Any] {
        [
            "avoidTolls": avoidTolls,
            "avoidHOV": avoidHOV,
            "avoidHighways": avoidHighways,
            "preferredProvider": preferredProvider
        ]
    }
}
