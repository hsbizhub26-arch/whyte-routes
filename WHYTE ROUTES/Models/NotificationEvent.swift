import Foundation
import FirebaseFirestore

// A record of one customer notification - real, persisted proof of
// what was sent and when, so an owner/manager can settle a "you never
// told me" dispute with an actual timestamp rather than a guess.
// Lives at companies/{companyId}/routes/{routeId}/stops/{stopId}/notifications/{id},
// id = "{stopId}_{type}" so a duplicate call for the same
// stop+type can never create a second document.
//
// Written exclusively by sendCustomerNotification (the Cloud
// Function, via the Admin SDK) - see NotificationRepository, which no
// longer has a client-side save(). This is read-only from the app.
struct NotificationEvent: Identifiable {
    var id: String
    var stopId: String
    var routeId: String
    var customerName: String
    var type: String            // "shiftStart" | "eta10" | "completed"
                                // (plus "trackingLink", and the retired
                                // "enRoute"/"arrived"/"eta15" still present
                                // in history written before they were removed)
    var message: String
    var contactMethod: String   // "sms" | "email" | "none" | "pending"
    var contactValue: String
    // "sending" (transaction wrote this, real send in flight) |
    // "accepted" (provider took it - not proof of final delivery) |
    // "failed" | "not_opted_in" | "type_disabled" (customer turned
    // off this specific eta10/completed update) |
    // "channel_disabled" (contact info exists but customer turned off
    // that channel) | "no_contact_on_file" | "not_entitled" (company's
    // plan doesn't include live notifications) | "queued_for_morning"
    // (Quiet Hours active - held for the 6 AM batched summary send,
    // transitions to "accepted"/"failed" once that fires) |
    // "skipped_quiet_hours" (a live-only ping during Quiet Hours -
    // never written to a document, same as gps_stale) | "gps_stale" (backend
    // independently verified the driver's last GPS update was too old
    // to trust for an eta10 trigger - never written to a
    // document, returned before one exists) | "duplicate_skipped" |
    // "debug_skipped" (DEBUG build, no real send attempted) |
    // "logged" (legacy records from before a real provider existed)
    var deliveryStatus: String
    var failureReason: String?
    var createdAt: Date
}

extension NotificationEvent {
    init?(from dict: [String: Any], id: String) {
        guard let stopId = dict["stopId"] as? String,
              let routeId = dict["routeId"] as? String,
              let type = dict["type"] as? String else {
            return nil
        }

        self.id = id
        self.stopId = stopId
        self.routeId = routeId
        self.customerName = dict["customerName"] as? String ?? "Customer"
        self.type = type
        self.message = dict["message"] as? String ?? ""
        self.contactMethod = dict["contactMethod"] as? String ?? "none"
        self.contactValue = dict["contactValue"] as? String ?? ""
        self.deliveryStatus = dict["deliveryStatus"] as? String ?? "logged"
        self.failureReason = dict["failureReason"] as? String

        if let ts = dict["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = Date()
        }
    }
}
