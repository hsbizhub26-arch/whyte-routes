import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// B7: records a proof clip with the system camera, capped at 15 s.
/// Returns the recorded file; VideoProofCompressor shrinks it and strips
/// the sound before it's queued.
struct VideoPicker: UIViewControllerRepresentable {
    var onPicked: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && (UIImagePickerController.availableMediaTypes(for: .camera) ?? []).contains(UTType.movie.identifier)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        if Self.isAvailable {
            picker.sourceType = .camera
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            picker.videoMaximumDuration = VideoProofCompressor.maxSeconds
            picker.videoQuality = .typeMedium
        } else {
            picker.sourceType = .photoLibrary
            picker.mediaTypes = [UTType.movie.identifier]
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VideoPicker
        init(_ parent: VideoPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                // The picker's file is temporary - copy it before dismissing.
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString).mov")
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { parent.onPicked(copy) }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
