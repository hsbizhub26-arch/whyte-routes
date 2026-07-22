import SwiftUI

struct OwnerDashboardView: View {

    @ObservedObject private var companySession = CompanySession.shared
    @StateObject private var driverVM = DriverViewModel()
    @StateObject private var routeService = RouteService.shared

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

                Spacer()
            }
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
