import Foundation

// VESTIGIAL. Navigation is now entirely in-app (NavigationSession),
// and nothing reads these values any more.
//
// The struct stays because companies/{id}.navigationSettings exists on
// every company document already written, and Company decodes it on
// every read. Deleting the type a week before submission would mean
// touching the model every screen depends on, to remove a field that
// costs nothing to keep decoding. It should go in a later cleanup,
// together with the stored field.
//
// What it used to do: configure which external map app a driver was
// handed off to, and pass avoid-tolls/highways hints to it. All three
// providers are gone, along with the handoff itself.
struct NavigationSettings {
    var avoidTolls: Bool
    var avoidHOV: Bool
    var avoidHighways: Bool
    var preferredProvider: String

    // nonisolated is now belt-and-braces rather than load-bearing -
    // the default used to resolve through a @MainActor type, which
    // made the synthesized memberwise init MainActor-isolated and
    // warned wherever NavigationSettings() was used as a default
    // argument. Kept explicit so that can't silently come back.
    nonisolated init(
        avoidTolls: Bool = true,
        avoidHOV: Bool = true,
        avoidHighways: Bool = false,
        preferredProvider: String = ""
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
            ?? ""
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
