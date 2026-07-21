import SwiftUI

struct DriverDetailView: View {

    @ObservedObject var session = DriverSession.shared

    var body: some View {
        VStack(spacing: 26) {

            // MARK: - Driver Card
            if let driver = session.driver {
                VStack(spacing: 12) {

                    // Avatar Circle
                    Circle()
                        .fill(driver.color.opacity(0.8))
                        .frame(width: 90, height: 90)
                        .overlay(
                            Text(driver.name.prefix(1))
                                .font(.largeTitle.bold())
                                .foregroundColor(.black)
                        )

                    VStack(spacing: 4) {
                        Text(driver.name)
                            .font(.title2.bold())
                            .foregroundColor(Color("WRThemeGold"))

                        if !driver.vehicle.isEmpty {
                            Text(driver.vehicle)
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.8))
                        }

                        if let phone = driver.phone {
                            Text("Phone: \(phone)")
                                .foregroundColor(.white.opacity(0.6))
                                .font(.footnote)
                        }
                    }
                }
                .padding()
                .background(Color.black.opacity(0.4))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color("WRThemeGold"), lineWidth: 1)
                )
                .padding(.horizontal)
            }

            Divider().overlay(Color("WRThemeGold"))

            // MARK: - Shift Summary (Route + Stops)
            if let route = session.assignedRoute {
                VStack(alignment: .leading, spacing: 12) {

                    Text("Current Route")
                        .font(.headline)
                        .foregroundColor(Color("WRThemeGold"))

                    Text(route.name)
                        .foregroundColor(.white)

                    HStack {
                        let completed = session.activeStops.filter { $0.isCompleted }.count
                        let total = session.activeStops.count

                        Text("Stops Completed:")
                            .foregroundColor(.white.opacity(0.6))

                        Text("\(completed) / \(total)")
                            .foregroundColor(Color("WRThemeGold"))
                            .bold()

                        Spacer()
                    }

                }
                .padding()
                .background(Color.black.opacity(0.3))
                .cornerRadius(14)
                .padding(.horizontal)
            } else {
                VStack(spacing: 8) {
                    Text("No Route Assigned")
                        .foregroundColor(.white.opacity(0.7))

                    Text("Your manager will assign your next route soon.")
                        .foregroundColor(.white.opacity(0.5))
                        .font(.caption)
                }
                .padding(.horizontal)
            }

            Spacer()

            // MARK: - Logout Button
            Button(role: .destructive) {
                DriverSession.shared.logout()
            } label: {
                Text("Log Out")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)

            Spacer()

        }
        .padding(.top)
        .background(Color("WRBlack").ignoresSafeArea())
        .navigationTitle("Driver Profile")
    }
}
