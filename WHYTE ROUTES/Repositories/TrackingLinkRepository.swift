import Foundation
import FirebaseFirestore

final class TrackingLinkRepository {

    private let db = Firestore.firestore()

    /// Tracking links for a specific company - explicit companyId
    /// parameter (not read from CompanySession) because listenTo is
    /// called from the unauthenticated customer tracking screen, which
    /// has no signed-in session and therefore no CompanySession state.
    /// Staff-only methods (create/deactivate) use the signed-in user's
    /// current company instead.
    private func trackingLinksRef(companyId: String) -> CollectionReference {
        db.collection("companies").document(companyId).collection("trackingLinks")
    }

    // MARK: - Create Tracking Link (staff, authenticated)
    func create(
        customerName: String,
        address: String,
        driverId: String,
        stopId: String,
        completion: @escaping (TrackingLink?) -> Void
    ) {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ TrackingLinkRepository: no current company set - cannot create link")
            completion(nil)
            return
        }

        let doc = trackingLinksRef(companyId: companyId).document()

        let data: [String: Any] = [
            "customerName": customerName,
            "address": address,
            "driverId": driverId,
            "stopId": stopId,
            "active": true,
            "createdAt": FieldValue.serverTimestamp()
        ]

        doc.setData(data) { error in
            if let error = error {
                print("❌ Failed to create tracking link:", error.localizedDescription)
                completion(nil)
                return
            }

            // Re-fetch the document so we get the real server timestamp
            doc.getDocument { snap, _ in
                guard let snap = snap,
                      let fullData = snap.data(),
                      let link = TrackingLink(from: fullData, id: snap.documentID, companyId: companyId)
                else {
                    completion(nil)
                    return
                }

                completion(link)
            }
        }
    }

    // MARK: - Deactivate Link (staff, authenticated)
    func deactivate(id: String) {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ TrackingLinkRepository: no current company set - cannot deactivate link")
            return
        }

        trackingLinksRef(companyId: companyId)
            .document(id)
            .updateData([
                "active": false,
                "completed": true,
                "completedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Listen to a Tracking Link (unauthenticated Customer Tracking View)
    func listenTo(companyId: String, linkId: String, handler: @escaping (TrackingLink?) -> Void) {
        trackingLinksRef(companyId: companyId)
            .document(linkId)
            .addSnapshotListener { snap, error in

                if let error = error {
                    print("❌ Failed listening to tracking link:", error.localizedDescription)
                    handler(nil)
                    return
                }

                guard let snap = snap, let data = snap.data() else {
                    handler(nil)
                    return
                }

                handler(TrackingLink(from: data, id: snap.documentID, companyId: companyId))
            }
    }
}
