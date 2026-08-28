import SwiftUI

// Two separate .sheet modifiers (isPresented + item) previously lived
// on ManagerDashboardView at once - tapping "Assign Driver" set both
// trigger conditions in the same action, and SwiftUI can't reliably
// present two independent sheets from one view. One of them (in
// practice, route detail instead of the assign-driver picker) won
// unpredictably. A single enum-backed sheet state removes the
// ambiguity entirely - there is exactly one sheet identity at a time.
private enum ManagerDashboardSheet: Identifiable {
    case routeDetail(Route)
    case assignDriver(Route)

    var id: String {
        switch self {
        case .routeDetail(let route): return "detail-\(route.id)"
        case .assignDriver(let route): return "assign-\(route.id)"
        }
    }
}

struct ManagerDashboardView: View {

    @StateObject private var routesVM = RoutesViewModel()
    @StateObject private var driversVM = DriverViewModel()

    @State private var selectedDriver: Driver?
    @State private var activeSheet: ManagerDashboardSheet?

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
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .routeDetail(let route):
                ManagerRouteDetailView(route: route)
            case .assignDriver(let route):
                ManagerAssignDriverSheet(route: route)
            }
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
                    activeSheet = .routeDetail(route)
                } assignDriverAction: {
                    activeSheet = .assignDriver(route)
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

