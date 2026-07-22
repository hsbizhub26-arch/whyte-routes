import SwiftUI
import FirebaseAuth

struct SettingsView: View {
    @EnvironmentObject var auth: AuthSession
    @State private var showReportIssue = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    Button("Sign Out") {
                        try? Auth.auth().signOut()
                    }
                    .foregroundColor(WRTheme.gold)
                    .listRowBackground(Color.black.opacity(0.2))

                    DeleteAccountSection()
                        .listRowBackground(Color.black.opacity(0.2))
                }
                Section {
                    Button {
                        showReportIssue = true
                    } label: {
                        Label("Report Issue", systemImage: "exclamationmark.bubble")
                    }
                    .listRowBackground(Color.black.opacity(0.2))
                } footer: {
                    Text("Found a bug or something confusing while testing? Tell us right away, not after the fact.")
                        .foregroundColor(.gray)
                }
                Section {
                    NavigationLink(destination: NavigationSettingsView()) {
                        Text("Navigation Settings")
                    }
                    .listRowBackground(Color.black.opacity(0.2))
                } header: {
                    Text("Driver Navigation")
                } footer: {
                    Text("Applied automatically whenever a driver taps Navigate on a stop.")
                        .foregroundColor(.gray)
                }
                Section {
                    NavigationLink(destination: PermissionsHelpView()) {
                        Text("Permissions Help")
                    }
                    .listRowBackground(Color.black.opacity(0.2))
                } header: {
                    Text("Privacy & Permissions")
                } footer: {
                    Text("Deleting your account cannot be undone.")
                        .foregroundColor(.gray)
                }
                Section {
                    Button("Email Support") {
#if canImport(UIKit)
                        if let url = URL(string: "mailto:dwlandscaping@hotmail.com?subject=WHYTE%20ROUTES%20Support&body=Username:%20teamdwlandscaping%0AUserID:%20devonwhyte9954%0A") {
                            UIApplication.shared.open(url)
                        }
#endif
                    }
                    .listRowBackground(Color.black.opacity(0.2))

                    Link("Privacy Policy", destination: URL(string: "https://teamdwlandscaping.com/privacy")!)
                        .listRowBackground(Color.black.opacity(0.2))

                    Link("Terms of Service", destination: URL(string: "https://teamdwlandscaping.com/terms")!)
                        .listRowBackground(Color.black.opacity(0.2))
                } header: {
                    Text("Support")
                } footer: {
                    Text("For urgent issues, include your driver ID and route ID in the email.")
                        .foregroundColor(.gray)
                }
            }
            .listStyle(.insetGrouped)
            .background(Color.black.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $showReportIssue) {
            ReportIssueView(
                reporterName: Auth.auth().currentUser?.email ?? "Unknown",
                reporterRole: auth.role.rawValue
            )
        }
    }
}

#Preview {
    SettingsView()
}
