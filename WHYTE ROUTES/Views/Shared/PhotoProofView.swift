import SwiftUI

struct PhotoProofView: View {

    @State private var selectedImage: UIImage?
    @State private var showCamera = false
    @State private var uploadMessage = ""
    @State private var isUploading = false

    @StateObject var uploader = PhotoUploader()

    let stopId: String
    let driverId: String
    let type: String // "before" or "after"

    var body: some View {

        VStack(spacing: 20) {

            if let img = selectedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 300)
                    .cornerRadius(10)
            }

            Button("Take \(type.capitalized) Photo") {
                showCamera = true
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.blue)
            .foregroundColor(.white)
            .cornerRadius(12)

            Button("Upload Photo") {
                Task {
                    await uploadImage()
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.green)
            .foregroundColor(.white)
            .cornerRadius(12)
            .disabled(selectedImage == nil)

            if isUploading {
                ProgressView("Uploading…")
            }

            if uploadMessage != "" {
                Text(uploadMessage)
                    .foregroundColor(.yellow)
            }
        }
        .padding()
        .sheet(isPresented: $showCamera) {
            ImagePicker(image: $selectedImage)
        }
    }

    func uploadImage() async {
        guard let img = selectedImage else { return }
        isUploading = true

        do {
            let url = try await uploader.uploadPhoto(image: img, stopId: stopId, driverId: driverId, type: type)
            uploadMessage = "Uploaded ✓"
        } catch {
            uploadMessage = "Failed: \(error.localizedDescription)"
        }

        isUploading = false
    }
}
