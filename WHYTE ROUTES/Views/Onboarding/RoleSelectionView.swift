import SwiftUI

struct RoleSelectionView: View {
    
    var body: some View {
        ZStack {
            WRTheme.gradient.ignoresSafeArea()
            
            VStack(spacing: 40) {
                
                Text("WHYTEROUTES")
                    .font(.largeTitle.bold())
                    .foregroundColor(WRTheme.gold)
                
                Text("Choose your role")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.headline)
                
                VStack(spacing: 24) {
                    
                    GoldButton(title: "ADMIN / OWNER") {
                        AdminSession.shared.isAdminLoggedIn = false
                        AdminSession.shared.adminName = ""
                        // Go to admin login screen
                        AppRouter.refresh()
                    }
                    
                    GoldButton(title: "DRIVER") {
                        DriverSession.shared.driver = nil
                        // Go to driver login screen
                        AppRouter.refresh()
                    }
                }
                .frame(maxWidth: 300)
                
                Spacer()
            }
            .padding(.top, 80)
        }
    }
}

extension AppRouter {
    static func refresh() {
        NotificationCenter.default.post(name: NSNotification.Name("AppRouterRefresh"), object: nil)
    }
}
