import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

// MARK: - Route Memory on the phone
//
// Holds what the app has learned about each property (read from
// companies/{c}/propertyStats, which only the Cloud Functions write),
// turns it into predictions, and opens/closes the "run" record for a
// shift. Everything here degrades to the size-tier defaults: if the
// stats can't be read (no signal, functions not deployed yet) the app
// simply says "estimate". Nothing here can block a driver.
@MainActor
final class RouteMemoryService: ObservableObject {

    static let shared = RouteMemoryService()
    private init() {}

    @Published private(set) var stats: [String: PropertyStats] = [:]
    /// The run this shift's visits belong to (runs/{shiftId}). nil when no
    /// run record exists - visits then simply carry no runId.
    @Published private(set) var currentRunId: String?
    /// "Heavy snow tonight" for the current run. Scales predictions only.
    @Published private(set) var snowActive = false

    private let db = Firestore.firestore()
    private var companyId: String? { CompanySession.shared.currentCompanyId }

    /// A property is the customer when the stop has one, otherwise the stop.
    static func propertyKey(for stop: Stop) -> String { stop.customerId ?? stop.id }

    func stats(for stop: Stop) -> PropertyStats? { stats[Self.propertyKey(for: stop)] }

    func prediction(for stop: Stop, snow: Bool? = nil) -> Prediction {
        RouteMemoryCore.predict(stats: stats(for: stop), tier: stop.sizeTier, snow: snow ?? snowActive)
    }

    /// Total predicted SERVICE time for these stops (no drive times exist).
    func summary(for stops: [Stop], snow: Bool, start: Date) -> (total: Double, finish: Date, text: String) {
        let total = stops.reduce(0.0) { $0 + prediction(for: $1, snow: snow).sec }
        let tz = CompanySession.shared.currentCompany?.timeZoneIdentifier ?? "America/Toronto"
        let r = RouteMemoryCore.runSummary(stopCount: stops.count, totalServiceSec: total, start: start, tz: tz)
        return (total, r.finish, r.text)
    }

    // MARK: Stats

    /// Reads the learned stats for these stops. Failures are ignored on
    /// purpose: a property with no stats just uses its size-tier estimate.
    func loadStats(for stops: [Stop]) async {
        guard let companyId else { return }
        let keys = Set(stops.map(Self.propertyKey(for:)))
        await withTaskGroup(of: (String, PropertyStats?).self) { group in
            for key in keys {
                group.addTask {
                    let ref = Firestore.firestore().collection("companies").document(companyId)
                        .collection("propertyStats").document(key)
                    guard let snap = try? await ref.getDocument(), snap.exists, let d = snap.data() else { return (key, nil) }
                    let n = (d["visitCount"] as? NSNumber)?.intValue ?? 0
                    return (key, PropertyStats(visitCount: n, avgDurationSec: (d["avgDurationSec"] as? NSNumber)?.doubleValue))
                }
            }
            for await (key, s) in group { if let s { stats[key] = s } }
        }
    }

    // MARK: Runs (one per shift on a route)

    private func runKey(_ shiftId: String) -> String { "rm.run.\(shiftId)" }
    private func snowKey(_ shiftId: String) -> String { "rm.snow.\(shiftId)" }

    /// Creates runs/{shiftId}. Fire-and-forget like every other write on
    /// this path - the Firestore cache holds it until there is signal.
    func beginRun(shiftId: String, driver: Driver?, route: Route?, stops: [Stop], snow: Bool) {
        guard let companyId, let route, let uid = Auth.auth().currentUser?.uid ?? driver?.id else { return }
        let pending = stops.filter { $0.isPending }
        let start = Date()
        let sum = summary(for: pending, snow: snow, start: start)
        var d: [String: Any] = [
            "driverId": uid,
            "routeId": route.id,
            "routeName": route.name,
            "shiftId": shiftId,
            "startedAt": Timestamp(date: start),
            "stopCount": pending.count,
            "snowFactorActive": snow,
            "snowFactor": snow ? RouteMemory.SNOW_FACTOR : 1.0,
            "predictedTotalSec": sum.total,
            "predictedFinishAt": Timestamp(date: sum.finish),
            "createdAt": FieldValue.serverTimestamp()
        ]
        if let name = driver?.name { d["driverName"] = name }
        db.collection("companies").document(companyId).collection("runs").document(shiftId).setData(d) { error in
            if let error { print("⚠️ RouteMemory: run \(shiftId) not recorded: \(error.localizedDescription)") }
        }
        currentRunId = shiftId
        snowActive = snow
        UserDefaults.standard.set(true, forKey: runKey(shiftId))
        UserDefaults.standard.set(snow, forKey: snowKey(shiftId))
    }

    /// After a relaunch mid-shift: pick the run back up.
    func restoreRun(shiftId: String) {
        guard UserDefaults.standard.bool(forKey: runKey(shiftId)) else { return }
        currentRunId = shiftId
        snowActive = UserDefaults.standard.bool(forKey: snowKey(shiftId))
    }

    func endRun() {
        defer { currentRunId = nil; snowActive = false }
        guard let companyId, let id = currentRunId else { return }
        db.collection("companies").document(companyId).collection("runs").document(id)
            .setData(["endedAt": Timestamp(date: Date())], merge: true) { error in
                if let error { print("⚠️ RouteMemory: couldn't close run \(id): \(error.localizedDescription)") }
            }
        UserDefaults.standard.removeObject(forKey: runKey(id))
        UserDefaults.standard.removeObject(forKey: snowKey(id))
    }

    func clear() {
        currentRunId = nil
        snowActive = false
        stats = [:]
    }
}
