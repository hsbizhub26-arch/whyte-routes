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
    /// sendCustomerNotification recognizes, which is now exactly three
    /// events: "shiftStart", "eta10" and "completed". The server still
    /// ACCEPTS the retired "enRoute"/"arrived"/"eta15" from older
    /// builds and drops them silently, so this app never needs to
    /// guess which server version it is talking to. Returns the real
    /// delivery
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

    /// Announces the start of a shift to every customer still waiting
    /// on this route. Fire-and-forget by design: the driver is already
    /// moving, and a failed text must never block Start Shift or put an
    /// error in front of someone about to drive. Returns how many were
    /// accepted so the caller can log it.
    ///
    /// Guarded by the same DEBUG switch as every other send here, which
    /// is what keeps a simulator run from texting real customers.
    @discardableResult
    func notifyShiftStart(routeId: String) async -> Int {
        guard isRealSendEnabled else {
            print("📋 [DEBUG build - no real notification sent] shiftStart for route \(routeId)")
            return 0
        }

        do {
            let result = try await functions.httpsCallable("sendShiftStartNotifications").call([
                "routeId": routeId
            ])
            let data = result.data as? [String: Any]
            let sent = data?["sent"] as? Int ?? 0
            let considered = data?["considered"] as? Int ?? 0
            print("📣 shiftStart: \(sent)/\(considered) customers texted for route \(routeId)")
            return sent
        } catch {
            print("⚠️ sendShiftStartNotifications failed for route \(routeId): \(error.localizedDescription)")
            return 0
        }
    }

    func history(routeId: String, stopId: String) async -> [NotificationEvent] {
        await repo.fetchHistory(routeId: routeId, stopId: stopId)
    }
}
