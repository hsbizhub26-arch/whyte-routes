import SwiftUI

/// Routes the user to the correct part of the app based on auth + role.
struct RoleRouterView: View {

    @EnvironmentObject var auth: AuthSession
    @ObservedObject private var companySession = CompanySession.shared

    var body: some View {
        Group {
            if auth.isLoading {
                LoadingScreen()
            }
            else if auth.user == nil {
                OwnerLoginView()     // login screen
            }
            else {
                switch auth.role {

                case .owner:
                    if companySession.currentCompanyId == nil {
                        CreateCompanyView()   // self-serve signup with no company yet
                    } else {
                        OwnerTabView()        // business owner - full admin access
                    }

                case .manager:
                    ManagerTabView()     // dispatcher / supervisor

                case .driver:
                    DriverTabView()      // driver assigned routes / tracking

                case .none:
                    OwnerLoginView()     // should not happen, but safe fallback
                }
            }
        }
        .animation(.easeInOut, value: auth.role)
        .animation(.easeInOut, value: auth.user)
    }
}
