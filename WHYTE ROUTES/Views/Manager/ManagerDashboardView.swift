import SwiftUI

struct ManagerDashboardView: View {

    @StateObject private var routesVM = RoutesViewModel()
    @StateObject private var driversVM = DriverViewModel()

    @State private var selectedRoute: Route?
    @State private var selectedDriver: Driver?
    @State private var showAssignSheet = false
    @State private var showRouteDetail = false

    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            VStack(spacing: 22) {

                header

                ScrollView {
                    VStack(spacing: 20) {

                        routeSection
                        driverSection
                    }
                    .padding(.horizontal)
                }

                Spacer(minLength: 20)
            }
            .opacity(showAssignSheet ? 0.2 : 1)
        }
        .sheet(isPresented: $showAssignSheet) {
            if let route = selectedRoute {
                ManagerAssignDriverSheet(route: route)
            }
        }
        .sheet(item: $selectedRoute) { route in
            ManagerRouteDetailView(route: route)
        }
        .navigationBarHidden(true)
    }
}

extension ManagerDashboardView {

    // MARK: HEADER
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {

            Text("Manager Dashboard")
                .font(.largeTitle.bold())
                .foregroundColor(Color("WRThemeGold"))

            Text("Your operations overview")
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.top, 20)
        .padding(.horizontal)
    }

    // MARK: ROUTES SECTION
    private var routeSection: some View {
        VStack(alignment: .leading, spacing: 8) {

            Text("Routes")
                .font(.title2.bold())
                .foregroundColor(Color("WRThemeGold"))

            ForEach(routesVM.routes) { route in
                ManagerRouteCard(route: route) {
                    selectedRoute = route
                } assignDriverAction: {
                    selectedRoute = route
                    showAssignSheet = true
                }
            }
        }
    }

    // MARK: DRIVERS SECTION
    private var driverSection: some View {
        VStack(alignment: .leading, spacing: 8) {

            Text("Drivers")
                .font(.title2.bold())
                .foregroundColor(Color("WRThemeGold"))

            ForEach(driversVM.drivers) { driver in
                ManagerDriverCard(driver: driver) {
                    selectedDriver = driver
                }
            }
        }
    }
}

