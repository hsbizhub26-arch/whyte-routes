import SwiftUI
import Firebase
import GoogleSignIn

@main
struct WHYTE_ROUTESApp: App {

    @StateObject private var auth = AuthSession.shared
    @StateObject private var purchaseManager = PurchaseManager()

    init() {
        FirebaseApp.configure()
        AuthSession.shared.listenForAuthChanges()

        // GIDSignIn needs its own client ID even though Firebase is
        // already configured - it doesn't read GoogleService-Info.plist
        // on its own, only FirebaseApp does.
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    var body: some Scene {
        WindowGroup {
            RoleRouterView()
                .environmentObject(auth)
                .environmentObject(purchaseManager)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
