import SwiftUI
import FirebaseAuth
import FirebaseFunctions

struct SettingsView: View {
    @EnvironmentObject var auth: AuthSession
    @State private var showReportIssue = false
    @State private var showSubscription = false
    @State private var alsoDrivesToggle = false
    @State private var testPhone = ""
    @State private var testOutcome: TestSmsOutcome?
    @State private var isSendingTest = false
    @State private var isCheckingTest = false
    @State private var quietHoursToggle = false
    @State private var smsBrandToggle = true

    /// The name customer texts open with when the toggle is on - the
    /// same fallback the server uses (smsBrand in functions/index.js).
    private var smsBrandName: String {
        let name = companySession.currentCompany?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "WHYTE ROUTES" : name
    }
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
    private static let supportEmail = "hsbizhub26@gmail.com"

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
                // Owner only: firestore.rules lets just the owner change
                // company settings, so a manager's tap would silently fail.
                if auth.role == .owner {
                    Section {
                        // Custom binding so only a real tap saves - setting
                        // the initial value in onAppear must not write.
                        Toggle("Show business name in customer texts", isOn: Binding(
                            get: { smsBrandToggle },
                            set: { newValue in
                                smsBrandToggle = newValue
                                guard let companyId = companySession.currentCompanyId else { return }
                                Task { await companyRepo.updateSmsShowBusinessName(companyId: companyId, enabled: newValue) }
                            }
                        ))
                        .tint(WRTheme.gold)
                        .listRowBackground(Color.black.opacity(0.2))
                    } footer: {
                        Text(smsBrandToggle
                             ? "Texts start with \"\(smsBrandName):\" - e.g. \"\(smsBrandName): Your driver is about 10 minutes away…\""
                             : "Texts start with \"WHYTE ROUTES:\" instead of your business name. Every text names a sender either way - carriers block texts that don't say who they're from.")
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
                        Text(isSendingTest ? "Sending… waiting for the carrier's answer" : "Send Test SMS")
                    }
                    .disabled(isSendingTest || isCheckingTest || testPhone.trimmingCharacters(in: .whitespaces).isEmpty)
                    .listRowBackground(Color.black.opacity(0.2))

                    if let testOutcome {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(testOutcome.headline)
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(testOutcome.color)
                            if let detail = testOutcome.detail {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundColor(testOutcome.color)
                            }
                            if let from = testOutcome.from {
                                Text("Sent from \(from)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            if let sid = testOutcome.sid {
                                // Selectable, so it can be pasted into
                                // Twilio's message log search.
                                Text("Twilio SID: \(sid)")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.gray)
                                    .textSelection(.enabled)
                            }
                        }
                        .listRowBackground(Color.black.opacity(0.2))

                        if testOutcome.kind == .pending, testOutcome.sid != nil {
                            Button(isCheckingTest ? "Checking…" : "Check Again") {
                                recheckTest()
                            }
                            .disabled(isCheckingTest)
                            .listRowBackground(Color.black.opacity(0.2))
                        }
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
                }
                // Sign Out sits well below the account tools and is
                // separated from Delete Account by the whole Support
                // section, so the safe, everyday action can't be
                // confused with the irreversible one.
                Section {
                    Button("Sign Out") {
                        try? Auth.auth().signOut()
                    }
                    .foregroundColor(WRTheme.gold)
                    .listRowBackground(Color.black.opacity(0.2))
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
                // The one irreversible action, deliberately the very
                // last thing on the screen and in its own section -
                // nowhere near Sign Out, so no one deletes their
                // account when they meant to log out.
                Section {
                    DeleteAccountSection()
                        .listRowBackground(Color.black.opacity(0.2))
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Deleting your account cannot be undone.")
                        .foregroundColor(.gray)
                }
            }
            .readableListWidth()
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
            smsBrandToggle = companySession.currentCompany?.smsShowBusinessName ?? true
        }
    }

    // THE SCREEN USED TO LIE. It showed "✅ Sent" whenever Twilio
    // accepted the API request - which it does instantly, before any
    // carrier has seen the text. On Nov 3 every test was then blocked
    // by the carrier (error 30007) a second later and the screen stayed
    // green. The function now waits for Twilio's final status and this
    // shows exactly that: green ONLY for a confirmed delivery.
    private func sendTest() {
        let phone = testPhone.trimmingCharacters(in: .whitespaces)
        isSendingTest = true
        testOutcome = nil
        Task {
            do {
                let result = try await Functions.functions().httpsCallable("sendTestNotification").call(["phone": phone])
                let outcome = TestSmsOutcome(data: result.data as? [String: Any])
                await MainActor.run {
                    testOutcome = outcome
                    isSendingTest = false
                }
            } catch {
                await MainActor.run {
                    testOutcome = TestSmsOutcome(kind: .failed, headline: "❌ Not sent", detail: error.localizedDescription)
                    isSendingTest = false
                }
            }
        }
    }

    private func recheckTest() {
        guard let sid = testOutcome?.sid else { return }
        isCheckingTest = true
        Task {
            do {
                let result = try await Functions.functions().httpsCallable("getTestNotificationStatus").call(["sid": sid])
                let outcome = TestSmsOutcome(data: result.data as? [String: Any])
                await MainActor.run {
                    testOutcome = outcome
                    isCheckingTest = false
                }
            } catch {
                await MainActor.run {
                    // Keep the last known outcome on screen; only say the
                    // check itself failed.
                    testOutcome?.detail = "Couldn't check right now: \(error.localizedDescription)"
                    isCheckingTest = false
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

/// What the test-SMS screen shows, built from sendTestNotification /
/// getTestNotificationStatus. Three states and only three: confirmed
/// delivered (green), definitely not delivered (red, with Twilio's
/// error code), or still waiting on the carrier (orange + Check Again).
private struct TestSmsOutcome {
    enum Kind { case delivered, failed, pending }

    let kind: Kind
    let headline: String
    var detail: String?
    var sid: String?
    var from: String?

    var color: Color {
        switch kind {
        case .delivered: return .green
        case .failed: return .red
        case .pending: return .orange
        }
    }

    init(kind: Kind, headline: String, detail: String? = nil, sid: String? = nil, from: String? = nil) {
        self.kind = kind
        self.headline = headline
        self.detail = detail
        self.sid = sid
        self.from = from
    }

    init(data: [String: Any]?) {
        let status = data?["status"] as? String ?? "unknown"
        // `final` is new; a server older than this build won't send it.
        // Treat its plain "accepted" as unconfirmed rather than green.
        let final = data?["final"] as? Bool ?? false
        let delivered = data?["delivered"] as? Bool ?? false
        let errorCode = (data?["errorCode"] as? NSNumber)?.intValue
        let reason = data?["failureReason"] as? String
        sid = data?["providerMessageId"] as? String
        from = data?["from"] as? String

        if delivered {
            kind = .delivered
            headline = "✅ Delivered - the carrier confirmed it reached the phone."
            detail = nil
        } else if final {
            kind = .failed
            headline = "❌ Not delivered (status: \(status)\(errorCode.map { ", error \($0)" } ?? ""))"
            detail = reason
        } else {
            kind = .pending
            headline = "⏳ Handed to the carrier, delivery not confirmed yet (status: \(status))"
            detail = reason
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
