import Foundation
import FirebaseAuth
import FirebaseFirestore

// MARK: - Reading runs and visits back (Shift History, Run Detail, Visit History)

struct RunItem: Identifiable {
    var id: String
    var driverId: String
    var driverName: String
    var routeName: String
    var startedAt: Date
    var endedAt: Date?
    var stopCount: Int
    var snowActive: Bool
}

struct VisitItem: Identifiable {
    var id: String
    var record: VisitRecord
    var stopId: String
    var driverId: String?
    var serviceDate: String?
}

extension VisitRecord {
    init(dict d: [String: Any]) {
        self.init()
        func date(_ k: String) -> Date? { (d[k] as? Timestamp)?.dateValue() }
        address = d["address"] as? String ?? ""
        driverName = d["driverName"] as? String ?? ""
        outcome = d["outcome"] as? String ?? "in_progress"
        correctedOutcome = d["correctedOutcome"] as? String
        source = d["source"] as? String
        enRouteAt = date("enRouteAt")
        arrivedAt = date("arrivedAt")
        completedAt = date("completedAt")
        correctedArrivedAt = date("correctedArrivedAt")
        correctedCompletedAt = date("correctedCompletedAt")
        createdAt = date("createdAt")
        reasonCode = d["reasonCode"] as? String
        reasonText = d["reasonText"] as? String
        flagged = d["flagged"] as? Bool
        flagRatio = (d["flagRatio"] as? NSNumber)?.doubleValue
    }
}

@MainActor
enum RouteMemoryHistory {

    static var companyId: String? { CompanySession.shared.currentCompanyId }
    static var timeZoneId: String { CompanySession.shared.currentCompany?.timeZoneIdentifier ?? "America/Toronto" }

    /// Owners and managers: every run. Drivers: only their own - the
    /// query itself says "mine", which is what the security rules need
    /// to allow it.
    static func runs(onlyDriver uid: String?) async -> [RunItem] {
        guard let companyId else { return [] }
        let col = Firestore.firestore().collection("companies").document(companyId).collection("runs")
        let query: Query = uid != nil
            ? col.whereField("driverId", isEqualTo: uid!)
            : col.order(by: "startedAt", descending: true).limit(to: 60)
        guard let snap = try? await query.getDocuments() else { return [] }
        let items: [RunItem] = snap.documents.compactMap { doc in
            let d = doc.data()
            guard let started = (d["startedAt"] as? Timestamp)?.dateValue(),
                  let driverId = d["driverId"] as? String else { return nil }
            return RunItem(id: doc.documentID, driverId: driverId,
                           driverName: d["driverName"] as? String ?? "Driver",
                           routeName: d["routeName"] as? String ?? "Route",
                           startedAt: started, endedAt: (d["endedAt"] as? Timestamp)?.dateValue(),
                           stopCount: (d["stopCount"] as? NSNumber)?.intValue ?? 0,
                           snowActive: d["snowFactorActive"] as? Bool ?? false)
        }
        return Array(items.sorted { $0.startedAt > $1.startedAt }.prefix(60))
    }

    static func visits(runId: String, onlyDriver uid: String?) async -> [VisitItem] {
        guard let companyId else { return [] }
        var q: Query = Firestore.firestore().collection("companies").document(companyId)
            .collection("serviceHistory").whereField("runId", isEqualTo: runId)
        if let uid { q = q.whereField("driverId", isEqualTo: uid) }
        guard let snap = try? await q.getDocuments() else { return [] }
        return items(snap).sorted { ($0.record.arrivedAt ?? .distantPast) < ($1.record.arrivedAt ?? .distantPast) }
    }

    /// Every past visit of one property, newest first (staff only).
    static func visits(propertyKey: String) async -> [VisitItem] {
        guard let companyId else { return [] }
        let col = Firestore.firestore().collection("companies").document(companyId).collection("serviceHistory")
        // Visits recorded before Route Memory have no propertyKey until the
        // backfill runs; they do carry customerId, so look there too.
        var all: [String: VisitItem] = [:]
        if let snap = try? await col.whereField("propertyKey", isEqualTo: propertyKey).getDocuments() {
            for v in items(snap) { all[v.id] = v }
        }
        if let snap = try? await col.whereField("customerId", isEqualTo: propertyKey).getDocuments() {
            for v in items(snap) { all[v.id] = v }
        }
        return Array(all.values).sorted {
            ($0.record.arrivedAt ?? $0.record.createdAt ?? .distantPast) > ($1.record.arrivedAt ?? $1.record.createdAt ?? .distantPast)
        }
    }

    private static func items(_ snap: QuerySnapshot) -> [VisitItem] {
        snap.documents.map { doc in
            let d = doc.data()
            return VisitItem(id: doc.documentID, record: VisitRecord(dict: d), stopId: d["stopId"] as? String ?? "",
                             driverId: d["driverId"] as? String, serviceDate: d["serviceDate"] as? String)
        }
    }
}
