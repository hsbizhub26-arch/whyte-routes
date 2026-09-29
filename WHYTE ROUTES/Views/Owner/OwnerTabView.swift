import SwiftUI

struct OwnerTabView: View {

    @EnvironmentObject var auth: AuthSession
    @State private var showReports = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

                // Owner-operators (one person, one truck) dispatch AND
                // drive - this tab is additive, not a role switch, and
                // only appears when they've opted in via Settings.
                // Reuses the real driver experience (map-first
                // dashboard, embedded: true so it doesn't nest a
                // second tab bar under this one - see DriverTabView)
                // rather than duplicating it. Placed here, in the
                // first five tabs, on purpose: iOS auto-collapses
                // anything past five into "More", and an owner who
                // drives checks this one daily - Reports/Team/Settings
                // don't need to be as immediately reachable.
                if auth.alsoDrives {
                    DriverTabView(embedded: true)
                        .tabItem {
                            Label("My Route", systemImage: "steeringwheel")
                        }
                }

                DriverReportsView()
                    .tabItem {
                        Label("Reports", systemImage: "doc.text")
                    }

                ManageEmployeesView()
                    .tabItem {
                        Label("Team", systemImage: "person.badge.plus")
                    }

                settingsTab
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .accentColor(WRTheme.gold)
        }
    }

    // SettingsView relies on the system "More" screen for its navigation
    // stack - but a full-width iPad shows every tab directly, with no More
    // screen, which left Settings with no title and a dead Permissions
    // Help link. iPhone and compact iPad keep the More path unchanged.
    @ViewBuilder
    private var settingsTab: some View {
        if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
            NavigationStack { SettingsView() }
        } else {
            SettingsView()
        }
    }

    private var permissionsSyncWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.black)
            VStack(alignment: .leading, spacing: 2) {
                Text("Owner access is active, but not saved to the server.")
                    .font(.footnote.bold())
                // Was: "...check the Firestore security rules for the
                // users collection." A paying contractor has no idea
                // what that is and can do nothing about it - it was a
                // note to ourselves left on a customer's home screen.
                Text("We couldn't save your account settings just now. Everything still works on this device - it should sort itself out shortly. If it keeps showing, get in touch from Settings.")
                    .font(.caption2)
            }
            .foregroundColor(.black)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WRTheme.gold)
    }
}
