import SwiftUI
import Firebase

@main
struct WHYTE_ROUTESApp: App {

    @StateObject private var auth = AuthSession.shared
    @StateObject private var entitlements = AppEntitlements.shared

    init() {
        FirebaseApp.configure()
        AppEntitlements.shared.restoreFromDefaults()
        AuthSession.shared.listenForAuthChanges()
    }

    var body: some Scene {
        WindowGroup {
            RoleRouterView()
                .environmentObject(auth)
                .environmentObject(entitlements)
                .preferredColorScheme(.dark)
        }
    }
}
