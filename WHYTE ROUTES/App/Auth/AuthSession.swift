import Foundation
import Combine
import FirebaseAuth

// MARK: - AuthSession

final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    @Published var user: User? = nil
    @Published var role: UserRole = .none
    @Published var isLoading: Bool = true
    @Published var isPlatformAdmin: Bool = false

    /// True if this account's permissions are only active locally because
    /// the Firestore users/{uid} permissions document couldn't be read or
    /// written (most commonly: Firestore security rules blocking the write).
    /// Access still works via the fallback - this just means it isn't
    /// persisted server-side yet.
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
                    self?.isPlatformAdmin = false
                    CompanySession.shared.clear()
                    return
                }

                // 1. Sync legacy entitlements from server first, so the
                //    permission checks below always have the final say.
                await SubscriptionSyncService().syncEntitlements(uid: user.uid)

                // 2. Firestore users/{uid} document is the real source of
                //    truth for role + company membership + subscription.
                if var permissions = await UserPermissionsService.shared.fetch(uid: user.uid) {

                    // Self-heal: this document was created before
                    // platformAdmin/companyId/companyRole existed (or
                    // this account has since started owning a company).
                    // Backfill rather than silently downgrading someone
                    // who should have platform access.
                    let shouldBePlatformAdmin = AccessControl.isPlatformAdmin(uid: user.uid, email: user.email)
                    if shouldBePlatformAdmin && !permissions.platformAdmin {
                        permissions.platformAdmin = true
                        permissions.role = .owner
                        await UserPermissionsService.shared.backfillIfMissing(
                            uid: user.uid,
                            fields: ["platformAdmin": true, "role": UserRole.owner.rawValue, "isAdmin": true]
                        )
                    }
                    if shouldBePlatformAdmin && permissions.companyId == nil {
                        if let owned = await CompanyRepository().fetchOwnedCompany(ownerUID: user.uid) {
                            permissions.companyId = owned.id
                            permissions.companyRole = "owner"
                            await UserPermissionsService.shared.backfillIfMissing(
                                uid: user.uid,
                                fields: ["companyId": owned.id, "companyRole": "owner"]
                            )
                        }
                    }

                    self.permissionsSyncFailed = false
                    self.isPlatformAdmin = permissions.platformAdmin
                    self.role = await self.resolveRole(
                        platformAdmin: permissions.platformAdmin,
                        companyId: permissions.companyId,
                        companyRole: permissions.companyRole,
                        fallbackRole: permissions.role
                    )
                    self.applySubscription(permissions.subscription)

                } else if AccessControl.isPlatformAdmin(uid: user.uid, email: user.email) {
                    // 3. Fallback for platform-owner accounts that haven't
                    //    been migrated to a Firestore permissions document
                    //    yet - grants access now, and creates the real
                    //    document so this fallback isn't needed again.
                    //    Also checks for a company this account already
                    //    owns (the dogfooding case: a platform admin who
                    //    is also a real company's owner) so both roles are
                    //    captured in the same document from the start.
                    self.isPlatformAdmin = true

                    let ownedCompany = await CompanyRepository().fetchOwnedCompany(ownerUID: user.uid)

                    self.role = await self.resolveRole(
                        platformAdmin: true,
                        companyId: ownedCompany?.id,
                        companyRole: ownedCompany != nil ? "owner" : nil,
                        fallbackRole: .owner
                    )
                    self.applySubscription("premiumPlus")

                    let persisted = await UserPermissionsService.shared.createIfNeeded(
                        uid: user.uid,
                        email: user.email ?? "",
                        role: .owner,
                        subscription: "premiumPlus",
                        isAdmin: true,
                        platformAdmin: true,
                        companyId: ownedCompany?.id,
                        companyRole: ownedCompany != nil ? "owner" : nil
                    )
                    self.permissionsSyncFailed = !persisted

                } else {
                    // No permissions document and not a platform admin -
                    // no company assignment exists yet either. Safe,
                    // low-privilege default until this account is added
                    // to a company (see Phase 2/6 onboarding work).
                    self.isPlatformAdmin = false
                    self.role = .driver
                    CompanySession.shared.clear()
                }

                // 4. Restore saved entitlements
                AppEntitlements.shared.restoreFromDefaults()
            }
        }
    }

    /// Resolves the app's UserRole (which UI tree to show) from the
    /// richer permissions model, and populates CompanySession as a
    /// side effect. Platform admins see the Owner-style dashboard
    /// unless they're currently acting as a company's Manager/Driver
    /// (uncommon, but keeps the two concepts independent per the
    /// "company permissions come through company membership" rule).
    private func resolveRole(
        platformAdmin: Bool,
        companyId: String?,
        companyRole: String?,
        fallbackRole: UserRole
    ) async -> UserRole {

        if let companyId {
            let company = await CompanyRepository().fetch(companyId: companyId)
            CompanySession.shared.currentCompanyId = companyId
            CompanySession.shared.currentCompany = company

            switch companyRole {
            case "manager": return .manager
            case "driver": return .driver
            default: return .owner // "owner" or unrecognized - safest default within a company context
            }
        }

        CompanySession.shared.clear()
        return platformAdmin ? .owner : fallbackRole
    }

    private func applySubscription(_ subscription: String) {
        let company = CompanySession.shared.currentCompany

        // A company's own tier takes priority when it's set to something
        // premium-equivalent (covers members of a comped/beta company,
        // not just the individual whitelist).
        if let company, company.subscriptionTier == "premiumPlus" || company.subscriptionTier == "enterprise" {
            AppEntitlements.shared.setPremiumPlus(unlocked: true, source: EntitlementSource.whitelist.rawValue)
            return
        }

        if subscription == "premiumPlus" {
            AppEntitlements.shared.setPremiumPlus(unlocked: true, source: EntitlementSource.whitelist.rawValue)
        } else if subscription == "premium" {
            AppEntitlements.shared.setPremium(unlocked: true, source: EntitlementSource.whitelist.rawValue)
        }
    }

    deinit {
        if let handle = authListener {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }
}
