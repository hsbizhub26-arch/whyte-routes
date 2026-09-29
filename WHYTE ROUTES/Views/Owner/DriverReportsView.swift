import SwiftUI

struct DriverReportsView: View {

    // Presented as a sheet from the owner dashboard with no way back -
    // it has a NavigationStack but never put anything in its toolbar.
    @Environment(\.dismiss) private var dismiss

    @StateObject private var routeService = RouteService.shared
    @StateObject private var driverVM = DriverViewModel()
    @ObservedObject private var access = FeatureAccessManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                WRTheme.gradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {

                        Text("Driver Reports")
                            .foregroundColor(WRTheme.gold)
                            .font(.largeTitle.bold())

                        ForEach(driverVM.drivers) { driver in
                            NavigationLink {
                                // Basic completed-stops/KM summary above
                                // is available to every tier; the
                                // travel/service-time breakdown behind
                                // this tap is the "Driver performance
                                // reports" feature named as Premium Plus.
                                if access.canAccessDriverPerformanceReports() {
                                    DriverTimeReportView(driver: driver)
                                } else {
                                    UpgradeRequiredView(
                                        featureName: "Driver Performance Reports",
                                        requiredTier: access.requiredTierForDriverPerformanceReports
                                    )
                                }
                            } label: {
                                reportCard(driver)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                    .tint(WRTheme.gold)
                    .readableContentWidth()
                }
            }
            .onAppear { routeService.loadRoutesOnce() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label("Close", systemImage: "chevron.down")
                            .font(.body.weight(.semibold))
                    }
                    .tint(WRTheme.gold)
                }
            }
        }
    }
}

extension DriverReportsView {

    func reportCard(_ driver: Driver) -> some View {
        let reports = routeService.reportFor(driver)

        return HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(driver.name)
                    .foregroundColor(WRTheme.gold)
                    .font(.headline)

                Text("Completed Stops: \(reports.completedStops)")
                    .foregroundColor(.white)
                Text("Total KM: \(reports.totalKM, specifier: "%.1f")")
                    .foregroundColor(.white)

                Text("Tap for shift & travel/service time →")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
        }
        .padding()
        .background(WRTheme.softBlack)
        .cornerRadius(14)
    }
}
