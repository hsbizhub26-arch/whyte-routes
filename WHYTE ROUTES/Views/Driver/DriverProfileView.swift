import SwiftUI
import FirebaseAuth

struct DriverProfileView: View {

    @ObservedObject private var session = DriverSession.shared
    @State private var showReportIssue = false

    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            VStack(spacing: 24) {

                // MARK: - Header
                VStack(spacing: 6) {
                    Text("Profile")
                        .foregroundColor(Color("WRThemeGold"))
                        .font(.largeTitle.bold())

                    Text("Driver Information")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.subheadline)
                }

                Divider().overlay(Color("WRThemeGold")).padding(.horizontal)

                // MARK: - Driver Info
                if let driver = session.driver {

                    VStack(spacing: 16) {

                        infoRow(title: "Name", value: driver.name)
                        infoRow(title: "Vehicle", value: driver.vehicle)
                        infoRow(title: "Phone", value: driver.phone ?? "N/A")

                        if let updated = driver.lastUpdated {
                            infoRow(
                                title: "Last Updated",
                                value: TimestampFormatter.shared.asTimeAgo(updated)
                            )
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.25))
                    .cornerRadius(16)
                }

                Spacer()

                // MARK: - Report Issue (the actual point of a beta day -
                // capture "where is that button?" the moment it happens)
                Button {
                    showReportIssue = true
                } label: {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                        .foregroundColor(Color("WRThemeGold"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.black.opacity(0.25))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color("WRThemeGold"), lineWidth: 1)
                        )
                }
                .padding(.horizontal)

                // MARK: - Logout
                Button(role: .destructive) {
                    // Signing out of Firebase is what actually matters -
                    // AuthSession's listener reacts to that and clears
                    // DriverSession/CompanySession/LocationService itself
                    // (see AuthSession.listenForAuthChanges). Calling
                    // session.logout() here directly without signing out
                    // of Firebase would leave the account still
                    // authenticated while the driver's own data vanished
                    // underneath it - that was the actual logout bug.
                    try? Auth.auth().signOut()
                } label: {
                    Text("Log Out")
                        .foregroundColor(.white)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.7))
                        .cornerRadius(16)
                }
                .padding(.horizontal)

                Spacer(minLength: 30)
            }
            .padding()
        }
        .sheet(isPresented: $showReportIssue) {
            ReportIssueView(
                reporterName: session.driver?.name ?? "Driver",
                reporterRole: "driver",
                routeId: session.assignedRoute?.id
            )
        }
    }

    // MARK: - Reusable Info Row
    func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(Color("WRThemeGold"))
                .font(.headline)

            Spacer()

            Text(value)
                .foregroundColor(.white)
                .font(.body)
        }
        .padding(.vertical, 4)
    }
}

