import SwiftUI

// The tool that makes a beta day worth something - captures "where
// is that button?"/"this took too many taps" the moment it happens,
// instead of relying on someone remembering it after the shift ends.
// Reporter name/role/route/timestamp are filled in automatically;
// the only thing a tester has to type is what actually happened.
struct ReportIssueView: View {

    @Environment(\.dismiss) private var dismiss

    let reporterName: String
    let reporterRole: String
    var routeId: String? = nil

    @State private var description = ""
    @State private var context = ""
    @State private var isSaving = false
    @State private var didSubmit = false
    @State private var errorMessage: String?

    private let repo = FeedbackRepository()

    var body: some View {
        NavigationStack {
            Form {
                if didSubmit {
                    Section {
                        Label("Thanks - this was recorded.", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                } else {
                    Section("What happened?") {
                        TextEditor(text: $description)
                            .frame(minHeight: 100)
                    }

                    Section("What were you doing? (optional)") {
                        TextField("e.g. trying to complete a stop", text: $context)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Report Issue")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                }
                if !didSubmit {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Sending…" : "Send") { submit() }
                            .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    }
                }
            }
        }
    }

    private func submit() {
        isSaving = true
        errorMessage = nil

        let report = FeedbackReport(
            id: UUID().uuidString,
            description: description,
            context: context.isEmpty ? nil : context,
            routeId: routeId,
            reporterName: reporterName,
            reporterRole: reporterRole,
            createdAt: Date()
        )

        repo.submit(report) { success in
            Task { @MainActor in
                isSaving = false
                if success {
                    didSubmit = true
                } else {
                    errorMessage = "Couldn't send - check your connection and try again."
                }
            }
        }
    }
}
