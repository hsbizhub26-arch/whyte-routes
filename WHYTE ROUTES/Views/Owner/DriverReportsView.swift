import SwiftUI

struct DriverReportsView: View {
    
    @StateObject private var routeService = RouteService.shared
    @StateObject private var driverService = DriverService.shared
    
    var body: some View {
        ZStack {
            AppTheme.black.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 20) {
                    
                    Text("Driver Reports")
                        .foregroundColor(AppTheme.gold)
                        .font(.largeTitle.bold())
                    
                    ForEach(driverService.drivers) { driver in
                        reportCard(driver)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 20)
                .tint(AppTheme.gold)
            }
        }
    }
}

extension DriverReportsView {

    func reportCard(_ driver: Driver) -> some View {
        let reports = routeService.reportFor(driver)
        
        return VStack(alignment: .leading, spacing: 8) {
            
            Text(driver.name)
                .foregroundColor(AppTheme.gold)
                .font(.headline)
            
            Text("Completed Stops: \(reports.completedStops)")
                .foregroundColor(AppTheme.textPrimary)
            Text("Total KM: \(reports.totalKM, specifier: "%.1f")")
                .foregroundColor(AppTheme.textPrimary)
            Text("Time Worked: \(reports.totalTimeMinutes) min")
                .foregroundColor(AppTheme.textPrimary)
            
        }
        .padding()
        .luxCard(cornerRadius: 14)
    }
}
