import SwiftUI

struct OwnerTabView: View {

    @EnvironmentObject var auth: AuthSession
    @State private var showReports = false

    var body: some View {
        VStack(spacing: 0) {

            if auth.permissionsSyncFailed {
                permissionsSyncWarning
            }

            TabView {

                OwnerDashboardView()
                    .tabItem {
                        Label("Home", systemImage: "house")
                    }

                CustomerListView()
                    .tabItem {
                        Label("Customers", systemImage: "person.3")
                    }

                AssignRoutesView()
                    .tabItem {
                        Label("Assign", systemImage: "square.and.pencil")
                    }

                LiveFleetMapView()
                    .tabItem {
                        Label("Fleet", systemImage: "map")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .accentColor(WRTheme.gold)
        }
    }

    private var permissionsSyncWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.black)
            VStack(alignment: .leading, spacing: 2) {
                Text("Owner access is active, but not saved to the server.")
                    .font(.footnote.bold())
                Text("Your permissions couldn't sync to Firestore. Access still works on this device - check the Firestore security rules for the users collection.")
                    .font(.caption2)
            }
            .foregroundColor(.black)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WRTheme.gold)
    }
}
