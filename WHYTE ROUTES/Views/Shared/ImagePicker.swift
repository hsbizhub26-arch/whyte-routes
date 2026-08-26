import SwiftUI
import UIKit

/// Camera capture for photo proof-of-work, falling back to the photo
/// library on devices/simulators with no camera.
struct ImagePicker: UIViewControllerRepresentable {

    @Binding var image: UIImage?
    // Optional - fires exactly once per real capture, unlike observing
    // `image` via onChange(of:), which UIImage can't support anyway
    // (it isn't Equatable) and which couldn't distinguish "picked a
    // new photo" from "picked the same photo again" besides.
    var onPicked: ((UIImage) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let picked = info[.originalImage] as? UIImage {
                parent.image = picked
                parent.onPicked?(picked)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
