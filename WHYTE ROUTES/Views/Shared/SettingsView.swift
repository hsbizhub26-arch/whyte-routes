import SwiftUI
import FirebaseAuth
import FirebaseFunctions

struct SettingsView: View {
    @EnvironmentObject var auth: AuthSession
    @State private var showReportIssue = false
    @State private var showSubscription = false
    @State private var alsoDrivesToggle = false
    @State private var testPhone = ""
    @State private var testResult: String?
    @State private var isSendingTest = false
    @State private var quietHoursToggle = false
    @ObservedObject private var companySession = CompanySession.shared
    private let companyRepo = CompanyRepository()

    // MARK: - Support
    // This was hardcoded to the PILOT CUSTOMER's own personal hotmail
    // address, with THEIR username and user id baked into the message
    // body - so every other company that installed the app mailed
    // their support requests to a landscaping contractor in Ontario,
    // introducing themselves as him. It leaked one customer's identity
    // to all the others and meant real support mail reached nobody.
    //
    // Worth moving to a support@ address on an owned domain once one
    // exists; until then this reaches a real monitored inbox, which is
    // what Apple's support-contact requirement actually needs.
    private static let supportEmail = "hopeseneoudom@icloud.com"

    /// Version and build, so a support mail says which build it came
    /// from without asking the user to go find it.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Prefilled with the identifiers of whoever is actually signed in,
    /// which is what makes a support mail answerable - and is the whole
    /// point of not hardcoding somebody else's.
    private var supportMailtoURL: URL? {
        let email = Auth.auth().currentUser?.email ?? "(not signed in)"
        let uid = Auth.auth().currentUser?.uid ?? "(unknown)"
        let company = companySession.currentCompany?.name ?? "(no company)"
        let companyId = companySession.currentCompanyId ?? "(none)"
        let body = """
            Please describe the problem here.

            ---
            Account: \(email)
            User ID: \(uid)
            Company: \(company) (\(companyId))
            App: \(Self.appVersion)
            """
        var components = URLComponents(string: "mailto:\(Self.supportEmail)")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: "WHYTE ROUTES Support"),
            URLQueryItem(name: "body", value: body)
        ]
        return components?.url
    }

    // No NavigationStack here on purpose - every place this view is
    // shown (ManagerTabView's explicit per-tab NavigationStack, and
    // the system "More" screen the owner's 7-tab layout collapses
    // into) already provides one. Wrapping another one around this
    // body nested a NavigationStack inside a NavigationStack, which
    // is what produced two stacked back buttons when pushing to
    // NavigationSettingsView.
    var body: some View {
        Group {
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
                    Text("Something broken or confusing? Tell us right away - it helps more than a review does.")
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
                // Owner-operators (one person, one truck) and managers
                // who also drive are real WHYTE ROUTES customers, not
                // an edge case - roles are permissions, not exclusive
                // identities. Hidden for role == .driver since a
                // driver already has the full driver experience as
                // their only view; toggling this would do nothing.
                if auth.role != .driver {
                    Section {
                        Toggle("I also drive routes", isOn: $alsoDrivesToggle)
                            .tint(WRTheme.gold)
                            .listRowBackground(Color.black.opacity(0.2))
                            .onChange(of: alsoDrivesToggle) { _, newValue in
                                setAlsoDrives(newValue)
                            }
                    } footer: {
                        Text("Adds a \"My Route\" tab alongside your \(auth.role == .owner ? "owner" : "manager") tools - for running your own route without giving up dispatch access.")
                            .foregroundColor(.gray)
                    }
                }
                Section {
                    Button {
                        showSubscription = true
                    } label: {
                        Label("Manage Subscription", systemImage: "star.fill")
                    }
                    .listRowBackground(Color.black.opacity(0.2))
                } header: {
                    Text("Billing")
                } footer: {
                    Text("View plan details, upgrade, or restore a previous purchase.")
                        .foregroundColor(.gray)
                }
                if auth.role != .driver {
                    Section {
                        Toggle("Quiet Hours (11 PM – 6 AM)", isOn: $quietHoursToggle)
                            .tint(WRTheme.gold)
                            .listRowBackground(Color.black.opacity(0.2))
                            .onChange(of: quietHoursToggle) { _, newValue in
                                guard let companyId = companySession.currentCompanyId else { return }
                                Task { await companyRepo.updateQuietHoursEnabled(companyId: companyId, enabled: newValue) }
                            }
                    } footer: {
                        Text("While on: live ETA/status texts are held overnight and every completed job is batched into one morning-summary text per customer instead. Drivers don't do anything differently - same buttons, same taps.")
                            .foregroundColor(.gray)
                    }
                }
                // A raw "send an SMS to an arbitrary number" harness,
                // built for wiring up Twilio and never intended for
                // customers. Every owner and manager could see it, and
                // it bills the real provider on every tap. Kept for our
                // own diagnostics, hidden from everyone else.
                if auth.isPlatformAdmin {
                Section {
                    TextField("+1XXXXXXXXXX", text: $testPhone)
                        .keyboardType(.phonePad)
                        .listRowBackground(Color.black.opacity(0.2))

                    Button {
                        sendTest()
                    } label: {
                        Text(isSendingTest ? "Sending…" : "Send Test SMS")
                    }
                    .disabled(isSendingTest || testPhone.trimmingCharacters(in: .whitespaces).isEmpty)
                    .listRowBackground(Color.black.opacity(0.2))

                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundColor(testResult.hasPrefix("✅") ? .green : .red)
                            .listRowBackground(Color.black.opacity(0.2))
                    }
                } header: {
                    Text("Test Notifications")
                } footer: {
                    Text("Sends a real SMS through the live provider, clearly marked as a test - never to a real customer record. Limited to 10 per day.")
                        .foregroundColor(.gray)
                }
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
                        if let url = supportMailtoURL {
                            UIApplication.shared.open(url)
                        }
#endif
                    }
                    .listRowBackground(Color.black.opacity(0.2))

                    Link("Privacy Policy", destination: URL(string: "https://whyte-routes.web.app/privacy")!)
                        .listRowBackground(Color.black.opacity(0.2))

                    Link("Terms of Service", destination: URL(string: "https://whyte-routes.web.app/terms")!)
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
        .sheet(isPresented: $showSubscription) {
            SubscriptionTierView()
        }
        .onAppear {
            alsoDrivesToggle = auth.alsoDrives
            quietHoursToggle = companySession.currentCompany?.quietHoursEnabled ?? false
        }
    }

    private func sendTest() {
        let phone = testPhone.trimmingCharacters(in: .whitespaces)
        isSendingTest = true
        testResult = nil
        Task {
            do {
                let result = try await Functions.functions().httpsCallable("sendTestNotification").call(["phone": phone])
                let data = result.data as? [String: Any]
                let accepted = data?["accepted"] as? Bool ?? false
                let failureReason = data?["failureReason"] as? String
                await MainActor.run {
                    testResult = accepted
                        ? "✅ Sent - check that phone for the text."
                        : "⚠️ Failed - \(failureReason ?? "unknown error")"
                    isSendingTest = false
                }
            } catch {
                await MainActor.run {
                    testResult = "⚠️ Failed - \(error.localizedDescription)"
                    isSendingTest = false
                }
            }
        }
    }

    private func setAlsoDrives(_ newValue: Bool) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        auth.alsoDrives = newValue
        Task {
            await UserPermissionsService.shared.backfillIfMissing(
                uid: uid,
                fields: ["alsoDrives": newValue]
            )
            if newValue {
                await auth.ensureDriverSessionBridged()
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
