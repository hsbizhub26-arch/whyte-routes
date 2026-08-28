import SwiftUI

struct DriverTabView: View {

    @ObservedObject private var session = DriverSession.shared
    @State private var selection: Int = 0

    // True only when hosted as the owner's "My Route" tab inside
    // OwnerTabView - a real driver signing in directly (RoleRouterView's
    // .driver case) always gets the full tab bar below, unchanged.
    // Embedded mode skips wrapping in a second TabView entirely
    // instead of just hiding tabItems, since a hidden-but-present
    // TabView still reserves its own bar height beneath the owner's
    // real tab bar - two navigation layers stacked was the actual
    // complaint, not just an unwanted label.
    var embedded: Bool = false

    var body: some View {
        Group {
            if embedded {
                DriverDashboardView(embedded: true)
            } else {
                fullTabView
            }
        }
        .onAppear { setupDriverOnLogin() }
    }

    private var fullTabView: some View {
        TabView(selection: $selection) {

            // DASHBOARD
            DriverDashboardView()
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Dashboard")
                }
                .tag(0)

            // ROUTE LIST
            DriverRouteView()
                .tabItem {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Route")
                }
                .tag(1)

            // PROFILE
            DriverProfileView()
                .tabItem {
                    Image(systemName: "person.crop.circle.fill")
                    Text("Profile")
                }
                .tag(3)
        }
        .accentColor(Color("WRThemeGold"))
        .toolbarBackground(Color("WRBlack"), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

private extension DriverTabView {
    /// Makes sure the driver session is synced and active route is loaded
    func setupDriverOnLogin() {
        // Refresh driver object
        DriverSession.shared.refresh()

        // Restore assigned route if app was closed
        if let driver = DriverSession.shared.driver,
           let routeId = driver.activeRoute {
            Task {
                await DriverSession.shared.loadAssignedRoute(routeId: routeId)
            }
        }
    }
}
