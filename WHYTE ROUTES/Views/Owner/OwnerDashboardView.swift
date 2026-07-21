import SwiftUI

struct OwnerDashboardView: View {
    
    @StateObject private var admin = AdminSession.shared
    @StateObject private var driverService = DriverService.shared
    @StateObject private var routeService = RouteService.shared
    
    @State private var showCustomers = false
    @State private var showAssign = false
    @State private var showReports = false
    @State private var showFleetMap = false
    
    var body: some View {
        ZStack {
            WRTheme.gradient.ignoresSafeArea()
            
            VStack(spacing: 20) {
                
                header
                
                HStack(spacing: 14) {
                    dashboardBox(title: "Drivers", value: "\(driverService.drivers.count)")
                    dashboardBox(title: "Active Routes", value: "\(routeService.routes.count)")
                }
                .padding(.horizontal)
                
                VStack(spacing: 14) {
                    GoldButton(title: "CUSTOMERS") { showCustomers = true }
                    GoldButton(title: "ASSIGN ROUTES") { showAssign = true }
                    GoldButton(title: "DRIVER REPORTS") { showReports = true }
                    GoldButton(title: "LIVE FLEET MAP") { showFleetMap = true }
                }
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .fullScreenCover(isPresented: $showCustomers) { CustomerListView() }
        .fullScreenCover(isPresented: $showAssign) { AssignRoutesView() }
        .fullScreenCover(isPresented: $showReports) { DriverReportsView() }
        .fullScreenCover(isPresented: $showFleetMap) { LiveFleetMapView() }
    }
}

extension OwnerDashboardView {
    
    var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Welcome")
                    .foregroundColor(.white.opacity(0.6))
                Text(admin.adminName)
                    .foregroundColor(WRTheme.gold)
                    .font(.title.bold())
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }
    
    func dashboardBox(title: String, value: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .foregroundColor(WRTheme.gold)
                .font(.title.bold())
            Text(title)
                .foregroundColor(.white)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(WRTheme.softBlack)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(WRTheme.gold.opacity(0.4), lineWidth: 2)
        )
    }
}
