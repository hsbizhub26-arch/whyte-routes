import Foundation
import AVFoundation

// B7: video proof - a short clip of the cleared driveway / cut lawn.
//
// Limits (all enforced here, on the phone, before anything is queued):
//  - at most 15 seconds (the camera stops at 15 s; anything longer
//    from elsewhere is trimmed to the first 15 s);
//  - re-encoded to 960x540 H.264 MP4; if that's still over the cap,
//    once more at 640x480;
//  - hard cap 12 MB - comfortably under the 20 MB storage rule;
//  - SOUND IS REMOVED. Only the video track is exported, so no audio
//    ever leaves the phone (privacy, and smaller files).
enum VideoProofCompressor {

    static let maxSeconds: Double = 15
    static let maxBytes = 12_000_000

    enum Failure: LocalizedError {
        case unreadable, tooLarge(Int), exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that video."
            case .tooLarge(let b): return "The clip is still \(b / 1_000_000) MB after compressing - record a shorter one."
            case .exportFailed(let m): return "Couldn't compress the video: \(m)"
            }
        }
    }

    struct Result {
        let url: URL
        let bytes: Int
        let seconds: Double
    }

    /// Compresses `source` into a new MP4 in the temp folder.
    static func compress(_ source: URL) async throws -> Result {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.unreadable }
        let duration = try await asset.load(.duration)
        let seconds = min(CMTimeGetSeconds(duration), maxSeconds)
        guard seconds > 0 else { throw Failure.unreadable }

        // Video-only composition: this is what drops the audio.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.unreadable
        }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        try track.insertTimeRange(range, of: videoTrack, at: .zero)
        track.preferredTransform = try await videoTrack.load(.preferredTransform)

        for preset in [AVAssetExportPreset960x540, AVAssetExportPreset640x480] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("proof-\(UUID().uuidString).mp4")
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            export.outputURL = out
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true
            await export.export()
            guard export.status == .completed else {
                throw Failure.exportFailed(export.error?.localizedDescription ?? "unknown error")
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            if bytes > 0 && bytes <= maxBytes { return Result(url: out, bytes: bytes, seconds: seconds) }
            try? FileManager.default.removeItem(at: out)
            if preset == AVAssetExportPreset640x480 { throw Failure.tooLarge(bytes) }
        }
        throw Failure.exportFailed("no export preset available")
    }
}
