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

    // MARK: - Driver's License Photo
    // Overwrites in place at a fixed filename (not a fresh UUID per
    // upload like proof-of-work) - a driver only ever has one current
    // license photo, and re-uploading should replace it, not pile up
    // old copies nobody's cleaning up in Storage.
    //
    // Returns the Storage PATH, not a download URL - see
    // Driver.licensePhotoPath for why a public download URL can't be
    // used here without defeating the access restriction entirely.
    func uploadLicensePhoto(image: UIImage, companyId: String, driverId: String) async throws -> String {
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw URLError(.badURL)
        }

        let path = "companies/\(companyId)/licenses/\(driverId)/license.jpg"
        let storageRef = storage.reference().child(path)
        _ = try await storageRef.putDataAsync(imageData)

        return path
    }

    /// Fetches the actual image bytes for a license photo path through
    /// the authenticated SDK call, which enforces storage.rules -
    /// unlike a download URL, this can't be reused by anyone who
    /// isn't actually authorized (see Driver.licensePhotoPath).
    func fetchLicensePhoto(path: String) async throws -> UIImage? {
        let data = try await storage.reference().child(path).data(maxSize: 8 * 1024 * 1024)
        return UIImage(data: data)
    }
}
