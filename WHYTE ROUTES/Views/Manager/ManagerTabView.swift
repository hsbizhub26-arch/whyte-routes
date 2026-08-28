import SwiftUI

struct ManagerTabView: View {

    @EnvironmentObject var auth: AuthSession

    var body: some View {
        TabView {

            NavigationStack {
                ManagerDashboardView()
            }
            .tabItem {
                Image(systemName: "speedometer")
                Text("Dashboard")
            }

            NavigationStack {
                ManagerRoutesView()
            }
            .tabItem {
                Image(systemName: "map")
                Text("Routes")
            }

            NavigationStack {
                ManagerDriversView()
            }
            .tabItem {
                Image(systemName: "person.3")
                Text("Drivers")
            }

            // Additive, not a role switch - see OwnerTabView for the
            // same pattern. Only appears when opted into via Settings.
            // embedded: true so this doesn't nest a second tab bar
            // under this one - a manager who also drives had the same
            // double-tab-bar problem owners did until this matched
            // the fix already made on the Owner side.
            if auth.alsoDrives {
                DriverTabView(embedded: true)
                    .tabItem {
                        Image(systemName: "steeringwheel")
                        Text("My Route")
                    }
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Image(systemName: "gear")
                Text("Settings")
            }
        }
        .accentColor(.yellow)
    }
}

