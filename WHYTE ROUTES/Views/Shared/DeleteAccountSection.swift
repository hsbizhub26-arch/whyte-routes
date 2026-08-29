import SwiftUI

/// The deletion control itself, with no container of its own, so it can
/// sit in a plain VStack screen as well as a Form.
///
/// This split exists because account deletion was reachable ONLY from
/// SettingsView, which only owners and managers ever see. A driver's
/// tabs are Dashboard / Route / Profile with no Settings anywhere, so a
/// driver - a real Firebase Auth account, created in-app, exactly what
/// Guideline 5.1.1(v) is about - had no way to delete it. The old view
/// was a `Section`, which cannot be dropped into a VStack, so there was
/// no cheap way to add one either.
struct DeleteAccountButton: View {
    @StateObject private var manager = DeleteAccountManager()
    @State private var showConfirmation = false

    /// Styled for a Form row by default; `standalone` gives the button
    /// the same full-width filled shape as Log Out on the driver's
    /// profile screen, so it doesn't look pasted in.
    var standalone: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            if manager.isDeleting {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .red))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Button(role: .destructive) {
                    showConfirmation = true
                } label: {
                    if standalone {
                        Text("Delete Account")
                            .foregroundColor(.red)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.black.opacity(0.25))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.red.opacity(0.6), lineWidth: 1)
                            )
                    } else {
                        Text("Delete Account")
                    }
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
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
    }
}

/// Form-row wrapper, for the screens that are Lists.
struct DeleteAccountSection: View {
    var body: some View {
        Section {
            DeleteAccountButton()
        }
    }
}
