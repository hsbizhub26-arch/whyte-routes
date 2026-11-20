import Foundation
import FirebaseFirestore
import FirebaseAuth

/// B5: loads everything the Season Log needs and saves owner snowfall
/// corrections.
///
/// Reads (all allowed by the deployed rules for owners/managers):
///   drivers/{id}/shifts since the season start, serviceHistory since
///   the season start.
/// Owner corrections live at companies/{c}/seasonLog/{night}. That
/// collection needs the rules block added in firestore.rules (B5) to be
/// DEPLOYED; until then reads/writes there are refused and the screen
/// says so instead of failing silently.
final class SeasonLogRepository {

    struct Loaded {
        let nights: [SeasonNight]
        let customers: [SeasonCustomerCount]
        let seasonLabel: String
        /// False until the seasonLog rules are deployed.
        let ownerEditsAvailable: Bool
    }

    private let db = Firestore.firestore()
    private let shiftRepo = ShiftRepository()

    private var companyId: String? { CompanySession.shared.currentCompanyId }
    private var timeZone: TimeZone {
        TimeZone(identifier: CompanySession.shared.currentCompany?.timeZoneIdentifier ?? "America/Toronto") ?? .current
    }

    func load(now: Date = Date()) async -> Loaded {
        let tz = timeZone
        let start = SeasonLogBuilder.seasonStart(containing: now, timeZone: tz)
        let label = SeasonLogBuilder.seasonLabel(start: start, timeZone: tz)
        guard let companyId else {
            return Loaded(nights: [], customers: [], seasonLabel: label, ownerEditsAvailable: false)
        }

        let drivers: [Driver] = await withCheckedContinuation { cont in
            FirestoreDriverRepository().fetchDrivers { result in
                cont.resume(returning: (try? result.get()) ?? [])
            }
        }
        var shifts: [SeasonShiftInput] = []
        for driver in drivers {
            for s in await shiftRepo.fetchShifts(driverId: driver.id, since: start) {
                shifts.append(SeasonShiftInput(driverId: driver.id, driverName: driver.name,
                                               startedAt: s.startedAt, endedAt: s.endedAt, snowfallCm: s.snowfallCm))
            }
        }

        var visits: [SeasonVisitInput] = []
        let startKey = SeasonLogBuilder.nightKey(for: start.addingTimeInterval(6 * 3600), timeZone: tz)
        if let snap = try? await db.collection("companies").document(companyId)
            .collection("serviceHistory")
            .whereField("serviceDate", isGreaterThanOrEqualTo: startKey)
            .getDocuments() {
            for doc in snap.documents {
                let d = doc.data()
                guard (d["outcome"] as? String) == "completed",
                      let done = (d["completedAt"] as? Timestamp)?.dateValue() else { continue }
                visits.append(SeasonVisitInput(customerId: d["customerId"] as? String,
                                               customerName: d["customerName"] as? String,
                                               completedAt: done))
            }
        }

        var overrides: [String: SeasonOverride] = [:]
        var editsAvailable = true
        do {
            let snap = try await db.collection("companies").document(companyId)
                .collection("seasonLog").getDocuments()
            for doc in snap.documents {
                if let cm = (doc.data()["snowfallCm"] as? NSNumber)?.intValue {
                    overrides[doc.documentID] = SeasonOverride(cm: cm, enteredAt: (doc.data()["enteredAt"] as? Timestamp)?.dateValue())
                }
            }
        } catch {
            editsAvailable = false   // rules not deployed yet
        }

        return Loaded(nights: SeasonLogBuilder.nights(shifts: shifts, visits: visits, overrides: overrides, timeZone: tz),
                      customers: SeasonLogBuilder.customerCounts(visits),
                      seasonLabel: label,
                      ownerEditsAvailable: editsAvailable)
    }

    /// Owner/manager correction for one night. Labelled "owner-entered"
    /// everywhere it's shown.
    func saveOwnerSnowfall(night: String, cm: Int) async throws {
        guard let companyId else { throw ShiftRepositoryError.noCompany }
        var data: [String: Any] = [
            "snowfallCm": cm,
            "source": "owner",
            "enteredAt": FieldValue.serverTimestamp()
        ]
        if let uid = Auth.auth().currentUser?.uid { data["enteredBy"] = uid }
        try await db.collection("companies").document(companyId)
            .collection("seasonLog").document(night).setData(data)
    }
}
