import Foundation
import FirebaseFirestore

final class ShiftRepository {

    private let db = Firestore.firestore()

    /// A driver's own shifts subcollection within the current company.
    /// nil (logged) if no company is set.
    private func shiftsRef(driverId: String) -> CollectionReference? {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ ShiftRepository: no current company set - cannot access shifts")
            return nil
        }
        return db.collection("companies").document(companyId)
            .collection("drivers").document(driverId)
            .collection("shifts")
    }

    /// Restores an in-progress shift on relaunch (app killed mid-shift).
    func fetchActiveShift(driverId: String) async -> Shift? {
        guard let ref = shiftsRef(driverId: driverId) else { return nil }
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

    @discardableResult
    func startShift(driverId: String) async -> Shift? {
        guard let ref = shiftsRef(driverId: driverId) else { return nil }
        let doc = ref.document()
        let shift = Shift(id: doc.documentID, driverId: driverId, startedAt: Date(), endedAt: nil, status: "active")
        do {
            try await doc.setData(shift.toDict())
            return shift
        } catch {
            print("⚠️ ShiftRepository.startShift(\(driverId)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func endShift(driverId: String, shiftId: String) async -> Bool {
        guard let ref = shiftsRef(driverId: driverId) else { return false }
        do {
            try await ref.document(shiftId).updateData([
                "endedAt": Timestamp(date: Date()),
                "status": "completed"
            ])
            return true
        } catch {
            print("⚠️ ShiftRepository.endShift(\(shiftId)) failed: \(error.localizedDescription)")
            return false
        }
    }
}
