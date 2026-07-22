import SwiftUI

// The actual dispute-resolution screen: "the customer says nobody
// told them" gets checked here, against a real timestamp instead of
// a guess.
struct NotificationHistoryView: View {

    let routeId: String
    let stop: Stop

    @Environment(\.dismiss) private var dismiss
    @State private var events: [NotificationEvent] = []
    @State private var isLoading = true

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if events.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bell.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No notifications sent yet for this stop.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.type.capitalized)
                                    .font(.headline)
                                Spacer()
                                Text(Self.formatter.string(from: event.createdAt))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(event.message)
                                .font(.subheadline)
                            Text(statusLabel(event))
                                .font(.caption)
                                .foregroundColor(event.deliveryStatus == "no_contact_on_file" ? .orange : .secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle(stop.customerName ?? "Notifications")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func statusLabel(_ event: NotificationEvent) -> String {
        switch event.deliveryStatus {
        case "no_contact_on_file":
            return "No phone/email on file - not actually sent."
        case "logged":
            return "Logged (\(event.contactMethod) to \(event.contactValue)) - no real provider connected yet."
        case "failed":
            return "Failed."
        default:
            return event.deliveryStatus
        }
    }

    private func load() {
        Task {
            let fetched = await NotificationService.shared.history(routeId: routeId, stopId: stop.id)
            await MainActor.run {
                events = fetched
                isLoading = false
            }
        }
    }
}
