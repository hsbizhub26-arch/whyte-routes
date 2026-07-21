import SwiftUI

struct MainAppRouter: View {

    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var entitlements: AppEntitlements

    var body: some View {
        Group {
            if auth.user == nil {
                AuthView()
            } else {
                routerForRole(auth.role)
                    .onChange(of: entitlements.premiumPlusUnlocked) { _ in
                        // Force refresh when Premium+ changes
                    }
                    .onChange(of: entitlements.premiumUnlocked) { _ in
                        // same for Premium
                    }
            }
        }
    }

    @ViewBuilder
    func routerForRole(_ role: UserRole) -> some View {
        switch role {
        case .owner, .fullAccess:
            ManagerTabView()
        case .standard:
            DriverTabView()
        default:
            ProgressView("Loading…")
        }
    }
}
