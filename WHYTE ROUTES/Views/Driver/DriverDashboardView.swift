import SwiftUI
import MapKit

struct DriverDashboardView: View {

    @ObservedObject var session = DriverSession.shared
    @ObservedObject var nextController = DriverNextStopController.shared

    var nextStop: Stop? {
        nextController.nextStop
    }

    var completedCount: Int {
        session.activeStops.filter { $0.isCompleted }.count
    }

    var totalStops: Int {
        session.activeStops.count
    }

    var progressText: String {
        "\(completedCount) / \(totalStops) stops completed"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                // MARK: - Header
                if let driver = session.driver {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Welcome,")
                                .font(.title3)
                                .foregroundColor(.white.opacity(0.8))

                            Text(driver.name)
                                .font(.largeTitle.bold())
                                .foregroundColor(Color("WRThemeGold"))
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                Divider().overlay(Color("WRThemeGold"))

                // MARK: - Route Summary
                if let route = session.assignedRoute {
                    VStack(alignment: .leading, spacing: 8) {

                        Text("Assigned Route")
                            .font(.title3.bold())
                            .foregroundColor(Color("WRThemeGold"))

                        Text(route.name)
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.8))

                        // Route progress bar
                        ProgressView(value: Double(completedCount),
                                     total: Double(max(1, totalStops)))
                            .tint(Color("WRThemeGold"))

                        Text(progressText)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))

                    }
                    .padding(.horizontal)

                } else {
                    VStack(spacing: 12) {
                        Text("No route assigned")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal)
                }

                Divider().overlay(Color("WRThemeGold"))

                // MARK: - Next Stop Preview
                if let stop = nextStop {
                    VStack(spacing: 12) {
                        Text("Next Stop")
                            .font(.title2.bold())
                            .foregroundColor(Color("WRThemeGold"))

                        Text(stop.customerName ?? "Customer")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text(stop.address)
                            .foregroundColor(.white.opacity(0.7))

                        NavigationLink {
                            DriverStopView(stop: stop)
                        } label: {
                            Text("Open Stop")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.black)
                                .foregroundColor(.white)
                                .cornerRadius(14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color("WRThemeGold"), lineWidth: 1)
                                )
                        }
                        .padding(.horizontal)

                    }
                } else if session.assignedRoute != nil {
                    VStack(spacing: 8) {
                        Text("Route Completed 🎉")
                            .font(.title2.bold())
                            .foregroundColor(Color.green)

                        Text("All stops finished.")
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                Spacer()
            }
            .padding(.top)
            .background(Color("WRBlack").ignoresSafeArea())
            .onAppear {
                nextController.updateNextStop()
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
    }
}

