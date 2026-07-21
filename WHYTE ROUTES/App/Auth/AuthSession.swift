import Foundation
import Combine
import FirebaseAuth

// MARK: - Supporting placeholders (replace with real implementations as needed)

/// Represents the user's role in the app.
enum UserRole {
    case none
    case standard
    case admin
}

/// Access control utilities. Replace with your real logic.
enum AccessControl {
    static func role(for email: String?) -> UserRole {
        // Example: make certain domains admins, otherwise standard
        guard let email = email else { return .none }
        if email.lowercased().hasSuffix("@example.com") {
            return .admin
        }
        return .standard
    }

    static func isWhitelisted(_ email: String?) -> Bool {
        // Example: trivial whitelist check
        guard let email = email else { return false }
        return ["test@example.com"].contains(email.lowercased())
    }
}

/// Source of entitlement changes. Replace with your app's real enum.
enum EntitlementSource: String {
    case whitelist
    case server
    case local
}

/// Stub service to sync entitlements with your backend. Replace with real implementation.
struct SubscriptionSyncService {
    func syncEntitlements(uid: String) async {
        // Simulate network sync delay
        try? await Task.sleep(nanoseconds: 150_000_000)
        // No-op: your real sync would update persisted entitlements
    }
}

// MARK: - AuthSession

final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    @Published var user: User? = nil
    @Published var role: UserRole = .none

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
