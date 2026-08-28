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
        stopLatitude: Double? = nil,
        stopLongitude: Double? = nil,
        completion: @escaping (TrackingLink?) -> Void
    ) {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ TrackingLinkRepository: no current company set - cannot create link")
            completion(nil)
            return
        }

        let doc = trackingLinksRef(companyId: companyId).document()

        var data: [String: Any] = [
            "customerName": customerName,
            "address": address,
            "driverId": driverId,
            "stopId": stopId,
            "active": true,
            "createdAt": FieldValue.serverTimestamp()
        ]
        if let stopLatitude { data["stopLatitude"] = stopLatitude }
        if let stopLongitude { data["stopLongitude"] = stopLongitude }

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

    // MARK: - Publish Live Position (driver, authenticated)
    // Writes ONLY a coordinate and an ETA - deliberately never the
    // driver's name, phone or id. This one document is world-readable
    // by anyone holding the link (see firestore.rules), so anything
    // written here is effectively public and must stay non-identifying.
    //
    // Always the same document id ("current"), so the customer's page
    // can listen to a known path and the collection can't grow a new
    // document per GPS ping.
    func publishLocation(
        companyId: String,
        linkId: String,
        latitude: Double,
        longitude: Double,
        etaMinutes: Int?
    ) {
        var data: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let etaMinutes { data["etaMinutes"] = etaMinutes }

        trackingLinksRef(companyId: companyId)
            .document(linkId)
            .collection("location")
            .document("current")
            .setData(data, merge: true)
    }

    /// The still-active link for a given stop, if one was ever created.
    /// Used by the driver's stop screen to know whether a customer is
    /// actually watching before it starts publishing position.
    func activeLink(forStopId stopId: String, completion: @escaping (TrackingLink?) -> Void) {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            completion(nil)
            return
        }
        trackingLinksRef(companyId: companyId)
            .whereField("stopId", isEqualTo: stopId)
            .whereField("active", isEqualTo: true)
            .limit(to: 1)
            .getDocuments { snap, error in
                guard error == nil, let doc = snap?.documents.first else {
                    completion(nil)
                    return
                }
                completion(TrackingLink(from: doc.data(), id: doc.documentID, companyId: companyId))
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
