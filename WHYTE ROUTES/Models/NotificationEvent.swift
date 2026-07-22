import Foundation
import FirebaseFirestore

// A record of one customer notification - real, persisted proof of
// what was sent and when, so an owner/manager can settle a "you never
// told me" dispute with an actual timestamp rather than a guess.
// Lives at companies/{companyId}/routes/{routeId}/stops/{stopId}/notifications/{id} -
// same nesting style as photos, so it's easy to find alongside the
// stop it belongs to.
struct NotificationEvent: Identifiable {
    var id: String
    var stopId: String
    var routeId: String
    var customerName: String
    var type: String            // "enRoute" | "arrived" | "completed"
    var message: String
    var contactMethod: String   // "sms" | "email" | "none"
    var contactValue: String
    var deliveryStatus: String  // "logged" | "sent" | "failed" | "no_contact_on_file"
    var createdAt: Date
}

extension NotificationEvent {
    init?(from dict: [String: Any], id: String) {
        guard let stopId = dict["stopId"] as? String,
              let routeId = dict["routeId"] as? String,
              let type = dict["type"] as? String,
              let message = dict["message"] as? String else {
            return nil
        }

        self.id = id
        self.stopId = stopId
        self.routeId = routeId
        self.customerName = dict["customerName"] as? String ?? "Customer"
        self.type = type
        self.message = message
        self.contactMethod = dict["contactMethod"] as? String ?? "none"
        self.contactValue = dict["contactValue"] as? String ?? ""
        self.deliveryStatus = dict["deliveryStatus"] as? String ?? "logged"

        if let ts = dict["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = Date()
        }
    }

    func toDict() -> [String: Any] {
        [
            "stopId": stopId,
            "routeId": routeId,
            "customerName": customerName,
            "type": type,
            "message": message,
            "contactMethod": contactMethod,
            "contactValue": contactValue,
            "deliveryStatus": deliveryStatus,
            "createdAt": Timestamp(date: createdAt)
        ]
    }
}
