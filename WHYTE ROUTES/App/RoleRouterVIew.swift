import SwiftUI

struct RoleRouterView: View {

    @EnvironmentObject var auth: AuthSession
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                LoadingView()
            } else {
                switch auth.role {
                case .driver:
                    DriverDashboardView()

                case .manager:
                    ManagerDashboardView()

                case .owner:
                    OwnerDashboardView()

                default:
                    AuthView()
                }
            }
        }
        .onAppear {
            Task {
                await auth.refreshRole()
                isLoading = false
            }
        }
    }
}
