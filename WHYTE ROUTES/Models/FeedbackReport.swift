import Foundation
import FirebaseFirestore

// What a beta tester submits via "Report Issue" - the actual point
// of this during a Day 1 field test: capture "where is that button?"
// the moment it happens, not rely on someone remembering to mention
// it later. Lives at companies/{companyId}/feedback/{id}.
struct FeedbackReport: Identifiable {
    var id: String
    var description: String
    var context: String?
    var routeId: String?
    var reporterName: String
    var reporterRole: String // "owner" | "manager" | "driver"
    var createdAt: Date
}

extension FeedbackReport {
    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "description": description,
            "reporterName": reporterName,
            "reporterRole": reporterRole,
            "createdAt": Timestamp(date: createdAt)
        ]
        if let context, !context.isEmpty { d["context"] = context }
        if let routeId { d["routeId"] = routeId }
        return d
    }
}
