import SwiftUI

struct DriverTabView: View {

    @ObservedObject private var session = DriverSession.shared
    @State private var selection: Int = 0

    var body: some View {
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

            // LIVE MAP
            DriverLiveMapView()
                .tabItem {
                    Image(systemName: "map.fill")
                    Text("Live Map")
                }
                .tag(2)

            // PROFILE
            DriverProfileView()
                .tabItem {
                    Image(systemName: "person.crop.circle.fill")
                    Text("Profile")
                }
                .tag(3)
        }
        .accentColor(Color("WRThemeGold"))
        .onAppear { setupDriverOnLogin() }
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
