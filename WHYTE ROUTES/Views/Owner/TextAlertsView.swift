import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore

// MARK: - Undelivered customer texts, surfaced to the owner
//
// companies/{c}/textAlerts is written by the twilioStatusCallback Cloud
// Function when a carrier comes back "undelivered" or "failed" for a
// customer text (e.g. 30007, filtered as spam). Before this, such a text
// stayed "accepted" in the log forever and nobody knew the customer never
// got it. Now the owner sees a banner on every tab, opens the list, and
// can text that customer from their own phone in one tap.

struct TextAlert: Identifiable {
    let id: String
    let customerName: String
    let type: String
    let phone: String?
    let message: String?
    let reason: String
    let createdAt: Date?

    init?(id: String, data: [String: Any]) {
        guard (data["resolved"] as? Bool) == false else { return nil }
        self.id = id
        self.customerName = data["customerName"] as? String ?? "Customer"
        self.type = data["type"] as? String ?? ""
        self.phone = data["phone"] as? String
        self.message = data["message"] as? String
        self.reason = data["reason"] as? String ?? "Not delivered."
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
    }

    /// Which text this was, in the owner's words.
    var whichText: String {
        switch type {
        case "shiftStart": return "\"We're on our way\" text"
        case "eta10": return "\"10 minutes away\" text"
        case "completed": return "\"Job done\" text"
        case "trackingLink": return "Tracking link text"
        default: return "Service text"
        }
    }

    /// The same words, ready to send by hand - minus the automated
    /// "Reply STOP" line, which means nothing from a personal phone.
    var handTextBody: String {
        (message ?? "")
            .replacingOccurrences(of: "\n\nReply STOP to opt out.", with: "")
            .replacingOccurrences(of: " Reply STOP to opt out.", with: "")
    }
}

@MainActor
final class TextAlertsStore: ObservableObject {
    static let shared = TextAlertsStore()
    private init() {}

    @Published private(set) var alerts: [TextAlert] = []
    /// This month's text-allowance state, written by the server
    /// (notificationUsage/{yyyy-MM}: smsSegments, smsCap, smsWarn80,
    /// smsCapReached). nil = nothing to warn about.
    @Published private(set) var allowanceMessage: String?
    private var listener: ListenerRegistration?
    private var usageListener: ListenerRegistration?
    private var listeningCompany: String?

    /// Idempotent: call from any owner screen's onAppear.
    func start() {
        guard let companyId = CompanySession.shared.currentCompanyId else { return }
        guard listeningCompany != companyId else { return }
        listener?.remove()
        usageListener?.remove()
        listeningCompany = companyId
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: CompanySession.shared.currentCompany?.timeZoneIdentifier ?? "America/Toronto")
        usageListener = Firestore.firestore()
            .collection("companies").document(companyId)
            .collection("notificationUsage").document(f.string(from: Date()))
            .addSnapshotListener { [weak self] snap, _ in
                let d = snap?.data() ?? [:]
                let used = d["smsSegments"] as? Int ?? 0
                let cap = d["smsCap"] as? Int ?? 0
                var msg: String?
                if d["smsCapReached"] as? Bool == true {
                    msg = "Monthly text allowance used (\(used) of \(cap)). Customer texts are paused until next month - tracking links and email still work."
                } else if d["smsWarn80"] as? Bool == true {
                    msg = "You've used \(used) of your \(cap) customer texts this month."
                }
                Task { @MainActor in self?.allowanceMessage = msg }
            }
        // No orderBy on purpose: resolved + createdAt would need a
        // composite index; the list is tiny, so it's sorted here.
        listener = Firestore.firestore()
            .collection("companies").document(companyId).collection("textAlerts")
            .whereField("resolved", isEqualTo: false)
            .addSnapshotListener { [weak self] snap, error in
                if let error {
                    print("⚠️ TextAlerts listener: \(error.localizedDescription)")
                    return
                }
                let items = (snap?.documents ?? [])
                    .compactMap { TextAlert(id: $0.documentID, data: $0.data()) }
                    .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                Task { @MainActor in self?.alerts = items }
            }
    }

    func stop() {
        listener?.remove()
        listener = nil
        usageListener?.remove()
        usageListener = nil
        allowanceMessage = nil
        listeningCompany = nil
        alerts = []
    }

    func markHandled(_ alert: TextAlert) {
        guard let companyId = CompanySession.shared.currentCompanyId else { return }
        var update: [String: Any] = ["resolved": true, "resolvedAt": FieldValue.serverTimestamp()]
        if let uid = Auth.auth().currentUser?.uid { update["resolvedBy"] = uid }
        Firestore.firestore()
            .collection("companies").document(companyId).collection("textAlerts")
            .document(alert.id).updateData(update) { error in
                if let error { print("⚠️ TextAlerts markHandled: \(error.localizedDescription)") }
            }
    }
}

// MARK: Banner (shown above the owner's tabs)

struct TextAlertsBanner: View {
    @ObservedObject private var store = TextAlertsStore.shared
    @State private var showList = false

    var body: some View {
        VStack(spacing: 0) {
            if let msg = store.allowanceMessage {
                HStack(spacing: 10) {
                    Image(systemName: "message.badge.filled.fill")
                    Text(msg).font(.footnote.weight(.semibold)).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.black)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(WRTheme.gold)
            }
            if !store.alerts.isEmpty {
                Button { showList = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.bubble.fill")
                        Text(store.alerts.count == 1
                             ? "1 customer text didn't arrive - tap to text them yourself"
                             : "\(store.alerts.count) customer texts didn't arrive - tap to text them yourself")
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows which customers didn't get their text")
            }
        }
        .onAppear { store.start() }
        .sheet(isPresented: $showList) { TextAlertsListView() }
    }
}

// MARK: List

struct TextAlertsListView: View {
    @ObservedObject private var store = TextAlertsStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The carrier didn't deliver these texts. Tap \"Text them myself\" to send the same message from your own phone, then mark it handled.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(store.alerts) { alert in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(alert.customerName).font(.headline)
                        Text(alert.whichText).font(.subheadline)
                        Text(alert.reason).font(.footnote).foregroundColor(.red)
                        if let when = alert.createdAt {
                            Text(when.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        HStack(spacing: 12) {
                            if let phone = alert.phone, !phone.isEmpty,
                               let url = smsURL(phone: phone, body: alert.handTextBody) {
                                Button("Text them myself") { openURL(url) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(WRTheme.gold)
                                    .foregroundColor(.black)
                            }
                            Button("Mark handled") { store.markHandled(alert) }
                                .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
                if store.alerts.isEmpty {
                    Text("All caught up - every recent text was delivered or handled.")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Texts that didn't arrive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func smsURL(phone: String, body: String) -> URL? {
        var c = URLComponents()
        c.scheme = "sms"
        c.path = phone
        if !body.isEmpty { c.queryItems = [URLQueryItem(name: "body", value: body)] }
        return c.url
    }
}
