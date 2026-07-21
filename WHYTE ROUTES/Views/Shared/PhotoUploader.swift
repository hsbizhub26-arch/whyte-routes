import SwiftUI
import FirebaseStorage
import FirebaseFirestore
import Combine

class PhotoUploader: ObservableObject {

    private let storage = Storage.storage()
    private let db = Firestore.firestore()

    func uploadPhoto(image: UIImage, stopId: String, driverId: String, type: String) async throws -> String {

        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw URLError(.badURL)
        }

        let fileId = UUID().uuidString
        let path = "photos/\(driverId)/\(stopId)/\(type)_\(fileId).jpg"

        let storageRef = storage.reference().child(path)

        let _ = try await storageRef.putDataAsync(imageData)

        // Get URL
        let url = try await storageRef.downloadURL()

        // Save metadata
        try await db.collection("stops").document(stopId)
            .collection("photos").document(fileId)
            .setData([
                "url": url.absoluteString,
                "type": type, // "before" or "after"
                "driverId": driverId,
                "timestamp": FieldValue.serverTimestamp()
            ])

        return url.absoluteString
    }
}
