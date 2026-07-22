import SwiftUI

// Company-level navigation preferences, applied automatically every
// time a driver taps Navigate on a stop - nobody has to configure
// anything per-route or per-driver.
struct NavigationSettingsView: View {

    @ObservedObject private var companySession = CompanySession.shared
    @State private var settings = NavigationSettings()
    @State private var isSaving = false
    @State private var savedRecently = false
    @State private var errorMessage: String?

    private let repo = CompanyRepository()

    var body: some View {
        Form {
            Section("Preferred Navigation App") {
                Picker("App", selection: $settings.preferredProvider) {
                    Text("Apple Maps").tag(NavigationService.MapApp.appleMaps.rawValue)
                    Text("Google Maps").tag(NavigationService.MapApp.googleMaps.rawValue)
                    Text("Waze").tag(NavigationService.MapApp.waze.rawValue)
                }
            }

            Section {
                Toggle("Avoid Tolls", isOn: $settings.avoidTolls)
                Toggle("Avoid HOV Lanes", isOn: $settings.avoidHOV)
                Toggle("Avoid Highways", isOn: $settings.avoidHighways)
            } header: {
                Text("Route Preferences")
            } footer: {
                // Honest, not glossed over: these preferences don't
                // work identically everywhere.
                Text("Only Google Maps' app supports avoiding tolls/highways when launched from WHYTE ROUTES. Apple Maps and Waze don't expose that option to outside apps, and none of the three support avoiding HOV lanes specifically - this stays saved and ready for when a provider does.")
                    .foregroundColor(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.footnote)
            }

            if savedRecently {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .navigationTitle("Navigation Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .disabled(isSaving)
            }
        }
        .onAppear {
            if let existing = companySession.currentCompany?.navigationSettings {
                settings = existing
            }
        }
    }

    private func save() {
        guard let companyId = companySession.currentCompanyId else { return }
        isSaving = true
        errorMessage = nil
        savedRecently = false

        Task {
            let success = await repo.updateNavigationSettings(companyId: companyId, settings: settings)
            await MainActor.run {
                isSaving = false
                if success {
                    companySession.currentCompany?.navigationSettings = settings
                    savedRecently = true
                } else {
                    errorMessage = "Couldn't save - check your connection and try again."
                }
            }
        }
    }
}
