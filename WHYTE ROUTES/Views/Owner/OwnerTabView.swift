import SwiftUI

struct OwnerTabView: View {
    
    @State private var showReports = false
    
    var body: some View {
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
