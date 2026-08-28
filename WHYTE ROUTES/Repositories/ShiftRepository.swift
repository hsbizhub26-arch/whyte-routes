import Foundation
import FirebaseFirestore

enum ShiftRepositoryError: LocalizedError {
    case noCompany

    var errorDescription: String? {
        switch self {
        case .noCompany: return "No company loaded yet - try signing out and back in."
        }
    }
}

final class ShiftRepository {

    private let db = Firestore.firestore()

    /// A driver's own shifts subcollection within the current company.
    private func shiftsRef(driverId: String) throws -> CollectionReference {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            throw ShiftRepositoryError.noCompany
        }
        return db.collection("companies").document(companyId)
            .collection("drivers").document(driverId)
            .collection("shifts")
    }

    /// Restores an in-progress shift on relaunch (app killed mid-shift).
    /// Failures here are non-fatal (just means the resume doesn't
    /// happen), so this one stays silent-on-error by design.
    func fetchActiveShift(driverId: String) async -> Shift? {
        guard let ref = try? shiftsRef(driverId: driverId) else { return nil }
        do {
            let snapshot = try await ref
                .whereField("status", isEqualTo: "active")
                .limit(to: 1)
                .getDocuments()
            guard let doc = snapshot.documents.first else { return nil }
            return Shift(from: doc.data(), id: doc.documentID)
        } catch {
            print("⚠️ ShiftRepository.fetchActiveShift(\(driverId)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // Checks Firestore itself for an existing active shift before
    // creating one - DriverSession's own `activeShift == nil` guard is
    // in-memory only, and restoreActiveShift() runs as a fire-and-
    // forget Task from setDriver(), not awaited. That leaves a real
    // window right after sign-in where a driver could tap Start Shift
    // before the restore resolves, otherwise creating a second,
    // orphaned "active" shift doc that silently corrupts hours/payroll
    // reporting (fetchActiveShift's limit(to: 1) would then return
    // whichever one Firestore feels like). Returning the real existing
    // shift instead of blindly creating a new one closes that for any
    // caller, not just this one call site.
    func startShift(driverId: String) async throws -> Shift {
        if let existing = await fetchActiveShift(driverId: driverId) {
            return existing
        }
        let ref = try shiftsRef(driverId: driverId)
        let doc = ref.document()
        let shift = Shift(id: doc.documentID, driverId: driverId, startedAt: Date(), endedAt: nil, status: "active")
        try await doc.setData(shift.toDict())
        return shift
    }

    func endShift(driverId: String, shiftId: String) async throws {
        let ref = try shiftsRef(driverId: driverId)
        try await ref.document(shiftId).updateData([
            "endedAt": Timestamp(date: Date()),
            "status": "completed"
        ])
    }

    /// Most recent shifts for the time-accounting report, newest first.
    func fetchRecentShifts(driverId: String, limit: Int = 10) async -> [Shift] {
        guard let ref = try? shiftsRef(driverId: driverId) else { return [] }
        do {
            let snapshot = try await ref
                .order(by: "startedAt", descending: true)
                .limit(to: limit)
                .getDocuments()
            return snapshot.documents.compactMap { Shift(from: $0.data(), id: $0.documentID) }
        } catch {
            print("⚠️ ShiftRepository.fetchRecentShifts(\(driverId)) failed: \(error.localizedDescription)")
            return []
        }
    }
}
