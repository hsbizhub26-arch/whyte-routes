import SwiftUI

struct DriverProfileView: View {

    @ObservedObject private var session = DriverSession.shared

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

                // MARK: - Logout
                Button(role: .destructive) {
                    session.logout()
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

