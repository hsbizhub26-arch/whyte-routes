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
        // refresh() already calls loadAssignedRoute, which looks the
        // driver's current route up by driverId and attaches the stops
        // listener. The loadAssignedRoute(routeId:) call that used to
        // follow it has an identical body - it ignores the routeId it
        // is handed and performs the same lookup - so this ran the
        // whole thing twice, attaching two un-removable listeners to
        // the same collection. Every stop change then delivered twice,
        // and each delivery re-ran TrackingBroadcastService.refreshLinks,
        // which issues one query per stop.
        DriverSession.shared.refresh()
    }
}
