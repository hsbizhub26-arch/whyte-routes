import Foundation
import FirebaseFunctions

// Real customer notifications - the actual send, the entitlement
// check, the consent check, and the duplicate-protection all happen
// server-side in sendCustomerNotification (functions/index.js). This
// class is deliberately thin: it calls that function and reports what
// came back. It never builds the message, never touches provider
// credentials, and never decides on its own whether something is
// "sent" - the Cloud Function's real response is the only source of
// truth for that.
@MainActor
final class NotificationService {

    static let shared = NotificationService()
    private init() {}

    private let repo = NotificationRepository()
    private lazy var functions = Functions.functions()

    // A DEBUG build (Xcode Run, simulator, local device builds) never
    // calls the real function - there's no way to accidentally text a
    // real customer while developing. TestFlight and App Store builds
    // are genuine Release builds and do call it for real.
    private var isRealSendEnabled: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// Fires a customer notification for a stop. `type` matches what
    /// sendCustomerNotification recognizes: "enRoute", "arrived",
    /// "completed", "eta15", or "eta10". Returns the real delivery
    /// status ("accepted", "failed", "not_entitled", "not_opted_in",
    /// "no_contact_on_file", "duplicate_skipped", or "debug_skipped"
    /// in DEBUG builds) - callers that just fire-and-forget can ignore
    /// it, but it's real, not a guess.
    @discardableResult
    func notify(stop: Stop, routeId: String, type: String) async -> String {
        guard isRealSendEnabled else {
            print("📋 [DEBUG build - no real notification sent] \(type) for stop \(stop.id)")
            return "debug_skipped"
        }

        do {
            let result = try await functions.httpsCallable("sendCustomerNotification").call([
                "routeId": routeId,
                "stopId": stop.id,
                "type": type
            ])
            let data = result.data as? [String: Any]
            return data?["deliveryStatus"] as? String ?? "unknown"
        } catch {
            print("⚠️ sendCustomerNotification failed for stop \(stop.id) (\(type)): \(error.localizedDescription)")
            return "failed"
        }
    }

    /// Convenience overload for the three job-status transitions,
    /// so DriverStopViewModel's existing call sites don't need to
    /// know the exact string types.
    @discardableResult
    func notify(stop: Stop, routeId: String, status: JobStatus) async -> String {
        await notify(stop: stop, routeId: routeId, type: status.rawValue)
    }

    func history(routeId: String, stopId: String) async -> [NotificationEvent] {
        await repo.fetchHistory(routeId: routeId, stopId: stopId)
    }
}
