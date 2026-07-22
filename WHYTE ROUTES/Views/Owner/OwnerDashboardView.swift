import SwiftUI

struct OwnerDashboardView: View {

    @ObservedObject private var companySession = CompanySession.shared
    @StateObject private var driverVM = DriverViewModel()
    @StateObject private var routeService = RouteService.shared
    @State private var showReports = false

    private var totalCompletedStops: Int {
        driverVM.drivers.reduce(0) { $0 + routeService.reportFor($1).completedStops }
    }

    var body: some View {
        ZStack {
            WRTheme.gradient.ignoresSafeArea()

            VStack(spacing: 20) {

                header

                HStack(spacing: 14) {
                    dashboardBox(title: "Drivers", value: "\(driverVM.drivers.count)")
                    dashboardBox(title: "Active Routes", value: "\(routeService.routes.count)")
                }
                .padding(.horizontal)

                driverReportsWidget

                Spacer()
            }
        }
        .onAppear { routeService.loadRoutesOnce() }
        .sheet(isPresented: $showReports) {
            DriverReportsView()
        }
    }
}

extension OwnerDashboardView {

    // Customers/Assign/Fleet/Reports used to be repeated here as
    // buttons AND as tabs below - identical destinations shown twice.
    // Removed the buttons; the tab bar is the one place to navigate
    // from now, this screen is just the at-a-glance overview.
    var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Welcome")
                    .foregroundColor(.white.opacity(0.6))
                Text(companySession.currentCompany?.name ?? "your team")
                    .foregroundColor(WRTheme.gold)
                    .font(.title.bold())
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }
    
    // Real summary data (completedStops is now correctly computed -
    // see RouteService.reportFor/stopsByRoute), not just a bare
    // shortcut - tapping it drills into the full Reports screen for
    // detail, same "summary card -> detail" pattern as any dashboard
    // widget, not a duplicate of the tab bar.
    var driverReportsWidget: some View {
        Button {
            showReports = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "doc.text.fill")
                    .font(.title2)
                    .foregroundColor(WRTheme.gold)
                    .frame(width: 46, height: 46)
                    .background(WRTheme.gold.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Driver Reports")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("\(totalCompletedStops) stop\(totalCompletedStops == 1 ? "" : "s") completed")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding()
            .background(WRTheme.softBlack)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(WRTheme.gold.opacity(0.4), lineWidth: 1)
            )
        }
        .padding(.horizontal)
    }

    func dashboardBox(title: String, value: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .foregroundColor(WRTheme.gold)
                .font(.title.bold())
            Text(title)
                .foregroundColor(.white)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(WRTheme.softBlack)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(WRTheme.gold.opacity(0.4), lineWidth: 2)
        )
    }
}
