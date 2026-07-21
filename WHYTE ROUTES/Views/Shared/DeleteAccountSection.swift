import SwiftUI

struct DeleteAccountSection: View {
    @StateObject private var manager = DeleteAccountManager()
    @State private var showConfirmation = false

    var body: some View {
        Section {
            if manager.isDeleting {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .red))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Button(role: .destructive) {
                    showConfirmation = true
                } label: {
                    Text("Delete Account")
                }
                .disabled(manager.isDeleting)
                .confirmationDialog(
                    "Are you sure you want to delete your account? This action cannot be undone.",
                    isPresented: $showConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete Account", role: .destructive) {
                        Task { await manager.deleteCurrentUser() }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }

            if let error = manager.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.footnote)
                    .padding(.top, 4)
            }
        }
    }
}
