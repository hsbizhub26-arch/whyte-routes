import SwiftUI
import MapKit
import Combine

struct DriverDashboardView: View {

    @ObservedObject var session = DriverSession.shared
    @ObservedObject var nextController = DriverNextStopController.shared

    @State private var now = Date()
    @State private var isTogglingShift = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var elapsedShiftText: String {
        guard let startedAt = session.activeShift?.startedAt else { return "0:00:00" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

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

                // MARK: - Shift Start/End
                shiftControl

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
                    VStack(spacing: 6) {
                        Image(systemName: "map")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.4))

                        Text("No route assigned for today")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.7))

                        Text("Contact your manager if you were expecting one.")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
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
            .onReceive(clock) { now = $0 }
        }
    }

    // MARK: - Shift Control
    private var shiftControl: some View {
        VStack(spacing: 10) {
            if let shift = session.activeShift, shift.isActive {
                Text("On Shift")
                    .font(.caption.bold())
                    .foregroundColor(.green)

                Text(elapsedShiftText)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Button {
                    isTogglingShift = true
                    Task {
                        await session.endShift()
                        isTogglingShift = false
                    }
                } label: {
                    Text(isTogglingShift ? "Ending…" : "End Shift")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .disabled(isTogglingShift)
            } else {
                Button {
                    isTogglingShift = true
                    Task {
                        await session.startShift()
                        isTogglingShift = false
                    }
                } label: {
                    Text(isTogglingShift ? "Starting…" : "Start Shift")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color("WRThemeGold"))
                        .foregroundColor(.black)
                        .fontWeight(.bold)
                        .cornerRadius(14)
                }
                .disabled(isTogglingShift)
            }

            if let shiftError = session.shiftError {
                Text(shiftError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
    }
}

