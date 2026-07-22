import Foundation

// A channel is anything capable of delivering one message to one
// contact. Swapping in real SMS (Twilio) or email (SendGrid/Firebase
// Trigger Email) later means writing one new type conforming to this
// protocol - nothing else in NotificationService, the callers in
// DriverStopView, or the NotificationEvent history schema needs to
// change.
protocol NotificationChannel {
    var method: String { get } // "sms" | "email"
    func send(to contact: String, message: String) async -> Bool
}

// No real provider is wired up yet (no Twilio/SendGrid account
// exists) - this logs exactly what WOULD have gone out and reports
// success, so the rest of the system (status tracking, the
// timestamped history an owner can point to in a dispute) is fully
// real and testable today. Swap for a real channel once a provider
// is chosen; nothing else changes.
struct LoggingChannel: NotificationChannel {
    let method: String

    func send(to contact: String, message: String) async -> Bool {
        print("📋 [Notification - log only, no real \(method) sent] to \(contact): \(message)")
        return true
    }
}

@MainActor
final class NotificationService {

    static let shared = NotificationService()
    private init() {}

    private let repo = NotificationRepository()

    /// Fires a customer notification for a stop's status change and
    /// records it to that stop's history regardless of whether a real
    /// contact method was on file - a "no contact on file" entry is
    /// still useful proof of what the system tried to do.
    @discardableResult
    func notify(stop: Stop, routeId: String, status: JobStatus) async -> NotificationEvent {
        let companyName = CompanySession.shared.currentCompany?.name ?? "Your service crew"
        let message = Self.message(for: status, companyName: companyName)

        let method: String
        let contact: String?
        if let phone = stop.customerPhone, !phone.trimmingCharacters(in: .whitespaces).isEmpty {
            method = "sms"
            contact = phone
        } else if let email = stop.customerEmail, !email.trimmingCharacters(in: .whitespaces).isEmpty {
            method = "email"
            contact = email
        } else {
            method = "none"
            contact = nil
        }

        var deliveryStatus = "no_contact_on_file"
        if let contact {
            let channel: NotificationChannel = LoggingChannel(method: method)
            let delivered = await channel.send(to: contact, message: message)
            deliveryStatus = delivered ? "logged" : "failed"
        }

        let event = NotificationEvent(
            id: UUID().uuidString,
            stopId: stop.id,
            routeId: routeId,
            customerName: stop.customerName ?? "Customer",
            type: status.rawValue,
            message: message,
            contactMethod: method,
            contactValue: contact ?? "",
            deliveryStatus: deliveryStatus,
            createdAt: Date()
        )

        await repo.save(event)
        return event
    }

    func history(routeId: String, stopId: String) async -> [NotificationEvent] {
        await repo.fetchHistory(routeId: routeId, stopId: stopId)
    }

    private static func message(for status: JobStatus, companyName: String) -> String {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        switch status {
        case .scheduled:
            return "\(companyName): your service has been scheduled."
        case .enRoute:
            return "\(companyName) is on the way."
        case .arrived:
            return "Your service team has arrived at \(time)."
        case .completed:
            return "Your service has been completed at \(time)."
        }
    }
}
