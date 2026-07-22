import SwiftUI
import Firebase

@main
struct WHYTE_ROUTESApp: App {

    @StateObject private var auth = AuthSession.shared
    @StateObject private var purchaseManager = PurchaseManager()

    init() {
        FirebaseApp.configure()
        AuthSession.shared.listenForAuthChanges()
    }

    var body: some Scene {
        WindowGroup {
            RoleRouterView()
                .environmentObject(auth)
                .environmentObject(purchaseManager)
                .preferredColorScheme(.dark)
        }
    }
}
