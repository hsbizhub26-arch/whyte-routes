import SwiftUI

struct ManagerTabView: View {

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

            NavigationStack {
                ManagerSettingsView()
            }
            .tabItem {
                Image(systemName: "gear")
                Text("Settings")
            }
        }
        .accentColor(.yellow)
    }
}

