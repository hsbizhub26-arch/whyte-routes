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
                                .foregroundColor(statusColor(event.deliveryStatus))
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

    private func statusColor(_ deliveryStatus: String) -> Color {
        switch deliveryStatus {
        case "accepted": return .green
        case "failed": return .red
        case "no_contact_on_file", "not_opted_in", "not_entitled", "type_disabled", "channel_disabled": return .orange
        case "queued_for_morning": return WRTheme.gold
        default: return .secondary
        }
    }

    private func statusLabel(_ event: NotificationEvent) -> String {
        switch event.deliveryStatus {
        case "accepted":
            return "✓ Sent (\(event.contactMethod) to \(event.contactValue))"
        case "sending":
            return "⏳ Sending…"
        case "failed":
            if let reason = event.failureReason, !reason.isEmpty {
                return "⚠️ Failed - \(reason)"
            }
            return "⚠️ Failed to send."
        case "not_entitled":
            return "Not sent - this plan doesn't include live customer notifications."
        case "not_opted_in":
            return "Not sent - customer hasn't opted in to notifications."
        case "type_disabled":
            return "Not sent - customer turned this specific update off."
        case "channel_disabled":
            return "Not sent - customer disabled that contact channel."
        case "queued_for_morning":
            return "Queued - Quiet Hours active, will send as part of the 6 AM morning summary."
        case "no_contact_on_file":
            return "No phone/email on file - not actually sent."
        case "duplicate_skipped":
            return "Already sent once for this stop - skipped to avoid a duplicate."
        case "debug_skipped":
            return "Development build - no real message was sent."
        case "logged":
            return "Logged (\(event.contactMethod) to \(event.contactValue)) - no real provider connected yet."
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
