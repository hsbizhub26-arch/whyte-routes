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

        KeyboardDoneBar.install()

        // B2: proof photos queue on the phone and upload when there's
        // signal - including ones left over from a previous launch.
        let uploader = PhotoUploader()
        PhotoProofQueue.shared.uploader = { photo, data in
            try await uploader.uploadQueued(photo, data: data)
        }
        PhotoProofQueue.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RoleRouterView()
                .environmentObject(auth)
                .environmentObject(purchaseManager)
                .preferredColorScheme(.dark)
                // Dragging any list/form/scroll view down slides the
                // keyboard away, like most iPhone apps. Set once here;
                // it's an environment value, so every screen inherits it.
                .scrollDismissesKeyboard(.interactively)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
