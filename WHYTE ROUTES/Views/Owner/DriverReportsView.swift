import SwiftUI

struct DriverReportsView: View {

    @StateObject private var routeService = RouteService.shared
    @StateObject private var driverVM = DriverViewModel()

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
                                DriverTimeReportView(driver: driver)
                            } label: {
                                reportCard(driver)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                    .tint(WRTheme.gold)
                }
            }
            .onAppear { routeService.loadRoutesOnce() }
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
