import Foundation
import Combine
import FirebaseAuth

// MARK: - AuthSession

final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    @Published var user: User? = nil
    @Published var role: UserRole = .none
    @Published var isLoading: Bool = true

    /// True if this account's owner access is only active locally because
    /// the Firestore users/{uid} permissions document couldn't be read or
    /// written (most commonly: Firestore security rules blocking the write).
    /// Access still works via the whitelist fallback - this just means it
    /// isn't persisted server-side yet.
    @Published var permissionsSyncFailed: Bool = false

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

                // 1. Sync legacy entitlements from server first, so the
                //    permission checks below always have the final say.
                await SubscriptionSyncService().syncEntitlements(uid: user.uid)

                // 2. Firestore users/{uid} document is the real source of
                //    truth for role + subscription.
                if let permissions = await UserPermissionsService.shared.fetch(uid: user.uid) {
                    self.role = permissions.role
                    self.permissionsSyncFailed = false

                    if permissions.subscription == "premiumPlus" {
                        AppEntitlements.shared.setPremiumPlus(unlocked: true, source: EntitlementSource.whitelist.rawValue)
                    } else if permissions.subscription == "premium" {
                        AppEntitlements.shared.setPremium(unlocked: true, source: EntitlementSource.whitelist.rawValue)
                    }

                } else if AccessControl.isOwner(uid: user.uid, email: user.email) {
                    // 3. Fallback for accounts that haven't been migrated to
                    //    a Firestore permissions document yet - grants owner
                    //    access now, and creates the real document so this
                    //    fallback isn't needed again next time.
                    self.role = .owner
                    AppEntitlements.shared.setPremiumPlus(unlocked: true, source: EntitlementSource.whitelist.rawValue)

                    let persisted = await UserPermissionsService.shared.createIfNeeded(
                        uid: user.uid,
                        email: user.email ?? "",
                        role: .owner,
                        subscription: "premiumPlus",
                        isAdmin: true
                    )
                    self.permissionsSyncFailed = !persisted

                } else {
                    self.role = .driver
                }

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
