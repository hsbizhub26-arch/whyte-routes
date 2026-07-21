import Foundation
import FirebaseFirestore

final class TrackingLinkRepository {

    private let db = Firestore.firestore()

    // MARK: - Create Tracking Link
    func create(
        customerName: String,
        address: String,
        driverId: String,
        stopId: String,
        completion: @escaping (TrackingLink?) -> Void
    ) {

        let doc = db.collection("trackingLinks").document()

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
                      let link = TrackingLink(from: fullData, id: snap.documentID)
                else {
                    completion(nil)
                    return
                }

                completion(link)
            }
        }
    }

    // MARK: - Deactivate Link
    func deactivate(id: String) {
        db.collection("trackingLinks")
            .document(id)
            .updateData([
                "active": false,
                "completed": true,
                "completedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Listen to a Tracking Link (Customer Tracking View)
    func listenTo(linkId: String, handler: @escaping (TrackingLink?) -> Void) {
        db.collection("trackingLinks")
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

                handler(TrackingLink(from: data, id: snap.documentID))
            }
    }
}
