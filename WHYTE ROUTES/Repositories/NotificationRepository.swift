import Foundation
import FirebaseFirestore

final class NotificationRepository {

    private let db = Firestore.firestore()

    private func notificationsRef(routeId: String, stopId: String) -> CollectionReference? {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ NotificationRepository: no current company set - cannot access notifications")
            return nil
        }
        return db.collection("companies").document(companyId)
            .collection("routes").document(routeId)
            .collection("stops").document(stopId)
            .collection("notifications")
    }

    // No client-side save() anymore - sendCustomerNotification (the
    // Cloud Function) is the only writer of notification records now,
    // using the Admin SDK. A client-side write here would let anyone
    // fabricate a fake "sent" entry in their own dispute history.

    /// The history for one stop - what a dispute call gets checked against.
    func fetchHistory(routeId: String, stopId: String) async -> [NotificationEvent] {
        guard let ref = notificationsRef(routeId: routeId, stopId: stopId) else { return [] }
        do {
            let snapshot = try await ref.order(by: "createdAt", descending: true).getDocuments()
            return snapshot.documents.compactMap { NotificationEvent(from: $0.data(), id: $0.documentID) }
        } catch {
            print("⚠️ NotificationRepository.fetchHistory failed: \(error.localizedDescription)")
            return []
        }
    }
}
