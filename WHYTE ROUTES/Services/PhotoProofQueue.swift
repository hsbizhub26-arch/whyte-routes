import Foundation
import UIKit
import Network
import Combine

// B2: proof photos that cannot be lost.
//
// The old flow uploaded straight from the capture sheet: on a weak
// signal it showed "Failed", and if the driver closed the sheet the
// photo was gone (A2 audit gap 1). It also uploaded the full-size image
// (3-8 MB, and a 48 MP shot could break the 10 MB storage rule - gap 2),
// stamped it with UPLOAD time rather than capture time (gap 3), and
// didn't link it to the visit record (gap 4).
//
// Now a capture is written to the phone's own storage FIRST - shrunk to
// well under the limit, with its capture time, GPS fix and visit id -
// and only then uploaded. The local copy is deleted only after both the
// image and its Firestore record are confirmed. Until then it survives
// dead zones, app restarts and crashes, and is retried whenever the
// network comes back, the app returns to the foreground, or every 30 s.
//
// This file has no Firebase dependency on purpose (the uploader is
// injected) so the queue logic can be tested on its own.

/// One captured photo waiting to upload. Its `id` is also the Storage
/// file name and the Firestore document id, so a retry overwrites the
/// same objects instead of creating duplicates.
struct PendingProofPhoto: Codable, Identifiable, Equatable {
    let id: String
    let companyId: String
    let routeId: String
    let stopId: String
    let driverId: String
    /// "arrival" or "completion".
    let type: String
    let capturedAt: Date
    let latitude: Double?
    let longitude: Double?
    /// Age of the GPS fix at capture, so a stale position is visibly stale.
    let gpsFixAgeSeconds: Int?
    /// ServiceHistory visit this photo belongs to (Stop.openVisitId).
    let visitId: String?
    /// "camera", or "library" on a device with no camera.
    let source: String
    let sizeBytes: Int
    var attempts: Int = 0
    var lastError: String?
    /// B7: nil/"photo" or "video".
    var kind: String? = nil
    /// B7: storage refused it (rules for this media type not deployed
    /// yet). Kept on the phone; retried once per app launch, not every
    /// 30 s, so it doesn't drain battery and data.
    var blocked: Bool? = nil

    var isVideo: Bool { kind == "video" }
    var fileExtension: String { isVideo ? "mp4" : "jpg" }
}

/// Thrown by the uploader when the server refuses the upload outright
/// (permission), as opposed to a network failure worth retrying soon.
struct ProofUploadNotPermitted: Error {}

/// Optional visible stamp burned into the bottom of a proof photo:
/// date + time it was taken, and the address. The capture time is
/// always recorded in the photo's record either way; this only decides
/// whether it's also printed on the picture.
enum ProofPhotoStamp {
    static func apply(_ image: UIImage, date: Date, address: String?, timeZone: TimeZone) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.timeZone = timeZone
        f.dateFormat = "MMM d, yyyy  h:mm a"
        var text = f.string(from: date)
        if let address, !address.isEmpty { text += "\n" + address }
        let fontSize = max(14, size.width * 0.032)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: UIColor.white
        ]
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            let str = NSAttributedString(string: text, attributes: attrs)
            let box = str.boundingRect(with: CGSize(width: size.width * 0.9, height: size.height),
                                       options: .usesLineFragmentOrigin, context: nil)
            let pad = fontSize * 0.6
            let band = CGRect(x: 0, y: size.height - box.height - pad * 2, width: size.width, height: box.height + pad * 2)
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIRectFill(band)
            str.draw(with: CGRect(x: pad, y: band.minY + pad, width: size.width - pad * 2, height: box.height),
                     options: .usesLineFragmentOrigin, context: nil)
        }
    }
}

enum ProofImageCompressor {

    /// Comfortably under the 10 MB storage rule and fast on weak LTE.
    static let maxBytes = 1_500_000
    static let maxDimension: CGFloat = 1600

    /// JPEG no larger than `maxBytes`: shrink to `maxDimension` on the
    /// long side, then step quality down, then step size down. Never
    /// returns nil for a real image.
    static func jpeg(_ image: UIImage, maxBytes: Int = maxBytes, maxDimension: CGFloat = maxDimension) -> Data? {
        var dimension = maxDimension
        while dimension >= 320 {
            let scaled = resized(image, maxDimension: dimension)
            for quality in stride(from: 0.75, through: 0.35, by: -0.1) {
                if let data = scaled.jpegData(compressionQuality: quality), data.count <= maxBytes {
                    return data
                }
            }
            dimension *= 0.75
        }
        return resized(image, maxDimension: 320).jpegData(compressionQuality: 0.3)
    }

    static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Disk storage for the queue: <dir>/<id>.jpg plus <id>.json. The image
/// is written before its metadata, so a crash between the two leaves an
/// orphan image (cleaned up later), never metadata pointing at nothing.
struct PhotoQueueStore {
    let directory: URL

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PhotoProofQueue", isDirectory: true)
    }

    init(directory: URL = PhotoQueueStore.defaultDirectory) {
        self.directory = directory
        var dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the queue out of iCloud/iTunes backups - it's transient.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    func imageURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).jpg") }
    func mediaURL(_ photo: PendingProofPhoto) -> URL { directory.appendingPathComponent("\(photo.id).\(photo.fileExtension)") }
    func metaURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    func save(_ photo: PendingProofPhoto, data: Data) throws {
        try data.write(to: mediaURL(photo), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try writeMeta(photo)
    }

    /// B7: moves an already-compressed file (video) into the queue.
    func save(_ photo: PendingProofPhoto, movingFile file: URL) throws {
        let dest = mediaURL(photo)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: file, to: dest)
        try writeMeta(photo)
    }

    func writeMeta(_ photo: PendingProofPhoto) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(photo).write(to: metaURL(photo.id), options: .atomic)
    }

    func imageData(_ id: String) -> Data? { try? Data(contentsOf: imageURL(id)) }
    func mediaData(_ photo: PendingProofPhoto) -> Data? { try? Data(contentsOf: mediaURL(photo)) }

    /// Every queued photo whose image is still present, oldest first.
    func all() -> [PendingProofPhoto] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> PendingProofPhoto? in
                guard let data = try? Data(contentsOf: url),
                      let photo = try? dec.decode(PendingProofPhoto.self, from: data),
                      FileManager.default.fileExists(atPath: mediaURL(photo).path) else { return nil }
                return photo
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: metaURL(id))
        try? FileManager.default.removeItem(at: imageURL(id))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).mp4"))
    }

    /// Images with no metadata (a crash mid-save) older than an hour.
    func removeOrphans(olderThan age: TimeInterval = 3600) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in files where url.pathExtension == "jpg" || url.pathExtension == "mp4" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !FileManager.default.fileExists(atPath: metaURL(id).path) else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > age { try? FileManager.default.removeItem(at: url) }
        }
    }
}

@MainActor
final class PhotoProofQueue: ObservableObject {

    static let shared = PhotoProofQueue()

    /// Uploads one photo (image + Firestore record). Set at app start
    /// (WHYTE_ROUTESApp) to the Firebase implementation in PhotoUploader.
    var uploader: ((PendingProofPhoto, Data) async throws -> Void)?

    @Published private(set) var pending: [PendingProofPhoto] = []
    @Published private(set) var isUploading = false

    private let store: PhotoQueueStore
    private var monitor: NWPathMonitor?
    private var retryTimer: Timer?

    init(store: PhotoQueueStore = PhotoQueueStore()) {
        self.store = store
        store.removeOrphans()
        // A new launch gets one fresh try at anything the server refused.
        for var p in store.all() where p.blocked == true {
            p.blocked = nil
            try? store.writeMeta(p)
        }
        pending = store.all()
    }

    /// B7: queues an already-compressed video clip (see VideoProofCompressor).
    @discardableResult
    func enqueueVideo(file: URL, bytes: Int, companyId: String, routeId: String, stopId: String, driverId: String,
                      visitId: String?, latitude: Double?, longitude: Double?, gpsFixAgeSeconds: Int?,
                      capturedAt: Date = Date()) throws -> PendingProofPhoto {
        let video = PendingProofPhoto(
            id: UUID().uuidString, companyId: companyId, routeId: routeId, stopId: stopId,
            driverId: driverId, type: "video", capturedAt: capturedAt,
            latitude: latitude, longitude: longitude, gpsFixAgeSeconds: gpsFixAgeSeconds,
            visitId: visitId, source: "camera", sizeBytes: bytes, kind: "video")
        try store.save(video, movingFile: file)
        pending = store.all()
        kick()
        return video
    }

    /// Items the server refused this launch (rules not deployed yet).
    var blockedCount: Int { pending.filter { $0.blocked == true }.count }

    /// Starts the network watch and the 30 s retry. Call once at launch.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.kick() }
        }
        monitor.start(queue: DispatchQueue(label: "PhotoProofQueue.network"))
        self.monitor = monitor
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.kick() }
        }
        kick()
    }

    func pendingCount(stopId: String, type: String? = nil) -> Int {
        pending.filter { $0.stopId == stopId && (type == nil || $0.type == type) }.count
    }

    /// Saves the photo to the phone, then tries to upload it. Returns
    /// once it's safely on disk - the driver never waits for the network.
    @discardableResult
    func enqueue(image: UIImage, companyId: String, routeId: String, stopId: String, driverId: String,
                 type: String, visitId: String?, latitude: Double?, longitude: Double?,
                 gpsFixAgeSeconds: Int?, source: String, capturedAt: Date = Date()) throws -> PendingProofPhoto {
        guard let data = ProofImageCompressor.jpeg(image) else {
            throw NSError(domain: "PhotoProofQueue", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't read that photo."])
        }
        let photo = PendingProofPhoto(
            id: UUID().uuidString, companyId: companyId, routeId: routeId, stopId: stopId,
            driverId: driverId, type: type, capturedAt: capturedAt,
            latitude: latitude, longitude: longitude, gpsFixAgeSeconds: gpsFixAgeSeconds,
            visitId: visitId, source: source, sizeBytes: data.count)
        try store.save(photo, data: data)
        pending = store.all()
        kick()
        return photo
    }

    /// Uploads everything queued, one at a time. Safe to call often.
    func kick() {
        guard !isUploading, uploader != nil, store.all().contains(where: { $0.blocked != true }) else { return }
        isUploading = true
        Task { await drain() }
    }

    /// Exposed for tests: one pass over the queue.
    func drain() async {
        defer {
            isUploading = false
            pending = store.all()
        }
        guard let uploader else { return }
        for var photo in store.all() where photo.blocked != true {
            guard let data = store.mediaData(photo) else { store.remove(photo.id); continue }
            do {
                try await uploader(photo, data)
                store.remove(photo.id)          // only after a confirmed upload
            } catch is ProofUploadNotPermitted {
                photo.blocked = true            // kept; next launch retries
                photo.lastError = "The server isn't accepting this yet."
                try? store.writeMeta(photo)
                continue
            } catch {
                photo.attempts += 1
                photo.lastError = error.localizedDescription
                try? store.writeMeta(photo)     // kept; retried next kick
                pending = store.all()
                return                          // offline is likely - stop this pass
            }
        }
    }
}
