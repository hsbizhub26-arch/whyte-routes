import SwiftUI
import FirebaseStorage
import FirebaseFirestore
import Combine

class PhotoUploader: ObservableObject {

    private let storage = Storage.storage()
    private let db = Firestore.firestore()

    // EVERY UPLOAD WAS BEING REFUSED. storage.rules only accepts files whose
    // contentType is image/* (isReasonableImage), and putDataAsync without
    // metadata uploads as application/octet-stream - so proof-of-work and
    // license photos both failed with "User does not have permission"
    // (found on the Nov 4 drive test; the bucket held zero photos).
    private static var jpegMetadata: StorageMetadata {
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        return metadata
    }

    func uploadPhoto(image: UIImage, companyId: String, routeId: String, stopId: String, driverId: String, type: String) async throws -> String {

        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw URLError(.badURL)
        }

        let fileId = UUID().uuidString
        // Storage path scoped by company so one tenant's photos can
        // never collide with or be enumerated alongside another's.
        let path = "companies/\(companyId)/photos/\(driverId)/\(stopId)/\(type)_\(fileId).jpg"

        let storageRef = storage.reference().child(path)

        let _ = try await storageRef.putDataAsync(imageData, metadata: Self.jpegMetadata)

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

    // MARK: - Queued proof photo (B2)
    //
    // Called by PhotoProofQueue. Idempotent: the photo's id is both the
    // Storage file name and the Firestore document id, so a retry after
    // a half-finished attempt overwrites the same objects. If the record
    // already exists (an earlier attempt got that far before the phone
    // lost signal), that counts as done - drivers may create photo
    // records but only staff may update them (firestore.rules), so
    // re-writing it would be refused forever.
    func uploadQueued(_ photo: PendingProofPhoto, data: Data) async throws {
        let docRef = db.collection("companies").document(photo.companyId)
            .collection("routes").document(photo.routeId)
            .collection("stops").document(photo.stopId)
            .collection("photos").document(photo.id)

        if (try? await docRef.getDocument())?.exists == true { return }

        // B7: videos go to their own folder with their own storage rule
        // (video/mp4, 20 MB cap). Until that rule is deployed Storage
        // refuses them - reported as ProofUploadNotPermitted so the queue
        // keeps the clip and stops hammering the server.
        let folder = photo.isVideo ? "videos" : "photos"
        let path = "companies/\(photo.companyId)/\(folder)/\(photo.driverId)/\(photo.stopId)/\(photo.type)_\(photo.id).\(photo.fileExtension)"
        let storageRef = storage.reference().child(path)
        let metadata: StorageMetadata
        if photo.isVideo {
            metadata = StorageMetadata()
            metadata.contentType = "video/mp4"
        } else {
            metadata = Self.jpegMetadata
        }
        do {
            _ = try await storageRef.putDataAsync(data, metadata: metadata)
        } catch {
            let ns = error as NSError
            if ns.domain == StorageErrorDomain, StorageErrorCode(rawValue: ns.code) == .unauthorized {
                throw ProofUploadNotPermitted()
            }
            throw error
        }
        let url = try await storageRef.downloadURL()

        var record: [String: Any] = [
            "url": url.absoluteString,
            "storagePath": path,
            "type": photo.type,
            "driverId": photo.driverId,
            // Upload time (kept for older screens that sort on it)...
            "timestamp": FieldValue.serverTimestamp(),
            // ...and the moment the photo was actually taken.
            "capturedAt": Timestamp(date: photo.capturedAt),
            "source": photo.source,
            "sizeBytes": photo.sizeBytes,
            "mediaType": photo.isVideo ? "video" : "photo"
        ]
        if let visitId = photo.visitId { record["visitId"] = visitId }
        if let lat = photo.latitude, let lon = photo.longitude {
            var gps: [String: Any] = ["latitude": lat, "longitude": lon]
            if let age = photo.gpsFixAgeSeconds { gps["fixAgeSeconds"] = age }
            record["gpsAtCapture"] = gps
        }
        try await docRef.setData(record)
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
        _ = try await storageRef.putDataAsync(imageData, metadata: Self.jpegMetadata)

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
