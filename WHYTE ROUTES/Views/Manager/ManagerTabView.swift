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
            if auth.alsoDrives {
                DriverTabView()
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

