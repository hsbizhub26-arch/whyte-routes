import SwiftUI
import FirebaseStorage
import FirebaseFirestore
import Combine

class PhotoUploader: ObservableObject {

    private let storage = Storage.storage()
    private let db = Firestore.firestore()

    func uploadPhoto(image: UIImage, companyId: String, routeId: String, stopId: String, driverId: String, type: String) async throws -> String {

        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw URLError(.badURL)
        }

        let fileId = UUID().uuidString
        // Storage path scoped by company so one tenant's photos can
        // never collide with or be enumerated alongside another's.
        let path = "companies/\(companyId)/photos/\(driverId)/\(stopId)/\(type)_\(fileId).jpg"

        let storageRef = storage.reference().child(path)

        let _ = try await storageRef.putDataAsync(imageData)

        let url = try await storageRef.downloadURL()

        // Metadata lives under the same companies/{companyId}/... tree
        // as everything else, not a top-level collection.
        try await db.collection("companies").document(companyId)
            .collection("routes").document(routeId)
            .collection("stops").document(stopId)
            .collection("photos").document(fileId)
            .setData([
                "url": url.absoluteString,
                "type": type, // "before" or "after" or "completion"
                "driverId": driverId,
                "timestamp": FieldValue.serverTimestamp()
            ])

        return url.absoluteString
    }
}
