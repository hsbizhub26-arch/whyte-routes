import SwiftUI

/// Routes the user to the correct part of the app based on auth + role + entitlements.
struct RoleRouterView: View {

    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var entitlements: AppEntitlements

    var body: some View {
        Group {
            if auth.isLoading {
                LoadingScreen()
            }
            else if auth.user == nil {
                LoginFlowView()     // login / signup screen
            }
            else {
                switch auth.role ?? .none {

                case .manager:
                    ManagerTabView()     // full business dashboard
                    
                case .driver:
                    DriverTabView()      // driver assigned routes / tracking
                    
                case .none:
                    LoginFlowView()      // should not happen, but safe fallback
                }
            }
        }
        .animation(.easeInOut, value: auth.role)
        .animation(.easeInOut, value: auth.user)
    }
}
