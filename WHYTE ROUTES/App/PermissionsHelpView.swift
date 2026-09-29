import SwiftUI

struct PermissionsHelpView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                permissionSection(
                    title: "Camera",
                    message: "We use the camera to capture before/after proof photos for each stop."
                )

                permissionSection(
                    title: "Photo Library",
                    message: "We access your library to show and upload your proof photos."
                )

                permissionSection(
                    title: "Location",
                    message: "We use your location to track job progress and detect arrival at stops, including in the background."
                )

#if canImport(UIKit)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
#endif
            }
            .padding()
            .readableContentWidth()
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func permissionSection(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            Text(message)
                .foregroundColor(.secondary)
        }
    }
}
