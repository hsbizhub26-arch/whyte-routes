import Foundation
import Combine
import FirebaseAuth

// MARK: - AuthSession

final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    @Published var user: User? = nil
    @Published var role: UserRole = .none
    @Published var isLoading: Bool = true

    private var authListener: AuthStateDidChangeListenerHandle?

    private init() {}

    func listenForAuthChanges() {
        // Remove existing listener if present
        if let handle = authListener {
            Auth.auth().removeStateDidChangeListener(handle)
            authListener = nil
        }

        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                defer { self?.isLoading = false }

                guard let self = self, let user = user else {
                    self?.role = .none
                    return
                }

                // 1. Assign local role instantly
                self.role = AccessControl.role(for: user.email)

                // 2. Whitelist unlock
                if AccessControl.isWhitelisted(user.email) {
                    AppEntitlements.shared.setPremiumPlus(
                        unlocked: true,
                        source: EntitlementSource.whitelist.rawValue
                    )
                }

                // 3. Sync entitlements from server
                await SubscriptionSyncService().syncEntitlements(uid: user.uid)

                // 4. Restore saved entitlements
                AppEntitlements.shared.restoreFromDefaults()
            }
        }
    }

    deinit {
        if let handle = authListener {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }
}
