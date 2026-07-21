import FirebaseFirestore

class TrackingLinkManager {

    private let db = Firestore.firestore()

    func generateTrackingLink(stopId: String, driverId: String, completion: @escaping (String) -> Void) {
        
        let linkId = UUID().uuidString
        
        let docRef = db.collection("trackingLinks").document(linkId)

        docRef.setData([
            "driverId": driverId,
            "stopId": stopId,
            "active": true,
            "createdAt": FieldValue.serverTimestamp()
        ]) { error in
            if error == nil {
                let trackingURL = "https://whyteroutes.app/tracking?id=\(linkId)"
                completion(trackingURL)
            }
        }
    }
}
