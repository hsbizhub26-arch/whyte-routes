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
    var avoidTolls: Bool = true
    var avoidHOV: Bool = true
    var avoidHighways: Bool = false
    var preferredProvider: String = NavigationService.MapApp.appleMaps.rawValue
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
