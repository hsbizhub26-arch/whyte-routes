import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

// MARK: - AuthSession

final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    @Published var user: User? = nil
    @Published var role: UserRole = .none
    @Published var isLoading: Bool = true
    /// True when a signed-in user's role/company has been resolving for
    /// longer than `loadTimeout`. isLoading stays true (the router must
    /// not fall through to the login screen for someone who IS signed
    /// in), but the UI can offer Retry / Sign out instead of an endless
    /// spinner. Cleared the moment loading finishes.
    @Published var loadTimedOut: Bool = false
    @Published var isPlatformAdmin: Bool = false

    /// True when an owner/manager has also opted into driving routes
    /// themselves (owner-operators - one person, one truck - are a real
    /// WHYTE ROUTES customer, not an edge case). Additive to `role`,
    /// never a replacement for it: an owner with this true still sees
    /// OwnerTabView, just with an extra "My Route" tab. Meaningless for
    /// role == .driver, who already has the full driver experience.
    @Published var alsoDrives: Bool = false

    /// True if this account's permissions are only active locally because
    /// the Firestore users/{uid} permissions document couldn't be read or
    /// written (most commonly: Firestore security rules blocking the write).
    /// Access still works via the fallback - this just means it isn't
    /// persisted server-side yet.
    @Published var permissionsSyncFailed: Bool = false

    private var authListener: AuthStateDidChangeListenerHandle?

    /// How long a signed-in user's permissions/company lookup may run
    /// before the loading screen offers Retry / Sign out. The lookup is
    /// several sequential Firestore reads with no timeout of their own,
    /// so on a bad connection it can otherwise spin indefinitely.
    private static let loadTimeout: Duration = .seconds(15)
    private var loadWatchdog: Task<Void, Never>?

    private init() {}

    private func startLoadWatchdog() {
        loadWatchdog?.cancel()
        loadWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            guard !Task.isCancelled, let self, self.isLoading else { return }
            self.loadTimedOut = true
        }
    }

    private func stopLoadWatchdog() {
        loadWatchdog?.cancel()
        loadWatchdog = nil
        loadTimedOut = false
    }

    /// Re-runs the sign-in resolution from scratch (Firebase re-fires the
    /// auth listener immediately with the current user). The original,
    /// still-pending attempt is not cancelled; whichever finishes first
    /// wins and both write the same values.
    @MainActor
    func retryLoad() {
        isLoading = true
        loadTimedOut = false
        listenForAuthChanges()
    }

    /// Watches this account's own permissions document so an offboarded
    /// person is signed out instead of sitting on a cached route.
    ///
    /// Server access dies the instant revokeEmployee commits - rules are
    /// re-evaluated on every request - but the app reads users/{uid}
    /// exactly ONCE, at sign-in, with no listener. Without this, a
    /// revoked driver keeps whatever stops were already downloaded on
    /// screen until they happen to relaunch, which looks to them like
    /// they are still on the job.
    ///
    /// Self-read is already permitted by firestore.rules, so this needs
    /// no rules change.
    private var membershipListener: ListenerRegistration?

    private func startMembershipWatch(uid: String) {
        membershipListener?.remove()
        membershipListener = Firestore.firestore()
            .collection("users").document(uid)
            .addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor in
                    guard let self, let snapshot, snapshot.exists else { return }
                    let data = snapshot.data() ?? [:]
                    // The KEY being gone is the signal. revokeEmployee
                    // uses FieldValue.delete() rather than writing null,
                    // precisely so a fresh invite can re-attach this
                    // person next season.
                    let stillAMember = data["companyId"] is String
                    let wasAMember = CompanySession.shared.currentCompanyId != nil
                    if wasAMember && !stillAMember {
                        safePrint("🔒 Membership revoked for \(uid) - signing out")
                        self.stopMembershipWatch()
                        CompanySession.shared.clear()
                        DriverSession.shared.logout()
                        try? Auth.auth().signOut()
                    }
                }
            }
    }

    private func stopMembershipWatch() {
        membershipListener?.remove()
        membershipListener = nil
    }

    func listenForAuthChanges() {
        // Remove existing listener if present
        if let handle = authListener {
            Auth.auth().removeStateDidChangeListener(handle)
            authListener = nil
        }

        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                if user != nil { self?.startLoadWatchdog() }
                defer {
                    self?.isLoading = false
                    self?.stopLoadWatchdog()
                }

                if user == nil { self?.stopMembershipWatch() }

                guard let self = self, let user = user else {
                    self?.role = .none
                    self?.isPlatformAdmin = false
                    self?.permissionsSyncFailed = false
                    self?.alsoDrives = false
                    CompanySession.shared.clear()
                    // Drops the tier back to Starter on sign-out, so a
                    // gated screen can't stay unlocked from the last
                    // account while a different one signs in.
                    FeatureAccessManager.shared.unbind()
                    DriverSession.shared.logout()
                    LocationService.shared.stopTracking()
                    return
                }

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
                            safePrint("🏢 Backfilled company membership: \(owned.name) (\(owned.id)) as owner")
                        } else {
                            safePrint("🏢 No owned company found for uid \(user.uid) - CompanySession stays empty")
                        }
                    }

                    // A LATE INVITE.
                    //
                    // The invite check below only ever ran when
                    // users/{uid} did not exist yet - i.e. only on the
                    // very first sign-in. So a driver who downloaded the
                    // app and signed in BEFORE their owner got round to
                    // inviting them was created as a company-less
                    // pending owner, and from then on took this branch
                    // forever: the invite would be created, sit there
                    // pending, and never be looked at again. They were
                    // locked out permanently, with no retry anywhere in
                    // the UI and nothing on screen explaining it. The
                    // order people do things in is not something we get
                    // to dictate, and this is the likelier order.
                    //
                    // Re-checking costs one query, and only for accounts
                    // that have no company at all.
                    if permissions.companyId == nil, !permissions.platformAdmin,
                       let invite = await self.findUsableInvite(for: user) {
                        let attached = await UserPermissionsService.shared.attachToCompany(
                            uid: user.uid,
                            companyId: invite.companyId,
                            companyRole: invite.role
                        )
                        if attached {
                            await InviteRepository().consume(invite)
                            permissions.companyId = invite.companyId
                            permissions.companyRole = invite.role
                            safePrint("🎟️ Late invite accepted for \(user.uid) -> \(invite.companyId) as \(invite.role)")
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

                    // Owner-operator support: additive, not a role
                    // switch - bridges DriverSession alongside the
                    // owner/manager role resolved above, so "My Route"
                    // has real data without touching self.role at all.
                    self.alsoDrives = permissions.alsoDrives
                    self.startMembershipWatch(uid: user.uid)
                    if permissions.alsoDrives,
                       let companyId = permissions.companyId,
                       permissions.companyRole != "driver" {
                        await self.bridgeDriverSession(companyId: companyId)
                    }
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
                    self.alsoDrives = false

                    let ownedCompany = await CompanyRepository().fetchOwnedCompany(ownerUID: user.uid)

                    self.role = await self.resolveRole(
                        platformAdmin: true,
                        companyId: ownedCompany?.id,
                        companyRole: ownedCompany != nil ? "owner" : nil,
                        fallbackRole: .owner
                    )
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
                    // No permissions document and not a platform admin.
                    // Before defaulting to a company-less driver, check
                    // whether this account's email or phone number
                    // matches a pending invite - if so, this is their
                    // first sign-in after being invited by a company
                    // owner, and we attach them to that company now.
                    // A driver can never grant themselves a company/role
                    // this way: the invite had to already exist, created
                    // by an owner, matched only by their own verified
                    // sign-in identity (see the Firestore rule).
                    self.isPlatformAdmin = false
                    self.alsoDrives = false

                    if let invite = await self.findUsableInvite(for: user) {
                        // Order matters, and is enforced by the Firestore
                        // rules, not just convention:
                        // 1. createIfNeeded() writes users/{uid} WHILE the
                        //    invite is still "pending" - the rule for
                        //    self-creating with companyId/companyRole set
                        //    only allows it when it matches a pending
                        //    invite addressed to this account's own
                        //    verified identity (see usableInviteMatches
                        //    in firestore.rules). This is what proves the
                        //    membership was actually granted by an owner,
                        //    not self-claimed.
                        // 2. consume() marks the invite "accepted" only
                        //    AFTER users/{uid} exists - so a failed create
                        //    never burns the invite.
                        // 3. resolveRole() bridges the driver session,
                        //    which creates companies/{companyId}/drivers/{uid};
                        //    that write's rule reads this account's
                        //    companyId from users/{uid}, so it must exist
                        //    by now too.
                        let persisted = await UserPermissionsService.shared.createIfNeeded(
                            uid: user.uid,
                            email: user.email ?? "",
                            // Was hardcoded .driver, so an invited
                            // MANAGER was stored as a driver. Harmless
                            // in practice - resolveRole and every rule
                            // branch off companyRole, not this - but the
                            // record was simply wrong, and the next
                            // person to trust this field would have been
                            // misled. The create rule requires it not be
                            // 'owner', which invite roles never are.
                            role: invite.role == "manager" ? .manager : .driver,
                            subscription: "free",
                            isAdmin: false,
                            platformAdmin: false,
                            companyId: invite.companyId,
                            companyRole: invite.role
                        )
                        self.permissionsSyncFailed = !persisted

                        if persisted {
                            await InviteRepository().consume(invite)
                        }

                        self.role = await self.resolveRole(
                            platformAdmin: false,
                            companyId: invite.companyId,
                            companyRole: invite.role,
                            fallbackRole: .driver
                        )
                    } else {
                        // Genuinely no invite waiting: this is a brand
                        // new self-serve signup. Persisted as a
                        // "pending owner" - role owner, no company yet -
                        // so RoleRouterView shows CreateCompanyView
                        // instead of OwnerTabView. Owning zero companies
                        // grants no real access anywhere, so this is
                        // safe to persist immediately rather than only
                        // holding it in memory (the old behavior here
                        // silently defaulted to role .driver with
                        // nothing ever written to Firestore, which is
                        // why self-serve signup had no path forward at
                        // all before this).
                        let persisted = await UserPermissionsService.shared.createIfNeeded(
                            uid: user.uid,
                            email: user.email ?? "",
                            role: .owner,
                            subscription: "free",
                            isAdmin: false,
                            platformAdmin: false
                        )
                        self.permissionsSyncFailed = !persisted
                        self.role = .owner
                        CompanySession.shared.clear()
                    }
                }
            }
        }
    }

    /// Checks for a pending, unexpired invite matching this user's
    /// verified email or phone number. Tries email first (the only
    /// method currently wired to a sign-in screen), then phone (ready
    /// for when phone auth is added - no changes needed here then).
    private func findUsableInvite(for user: User) async -> Invite? {
        if let email = user.email, !email.isEmpty {
            if let invite = await InviteRepository().lookupInvite(contactValue: email, method: "email") {
                return invite
            }
        }
        if let phone = user.phoneNumber, !phone.isEmpty {
            if let invite = await InviteRepository().lookupInvite(contactValue: phone, method: "phone") {
                return invite
            }
        }
        return nil
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
            // The one-shot fetch above gives resolveRole a value to log
            // and act on right now; the listener keeps it current for
            // the rest of the session, so a tier bought mid-session
            // actually takes effect - see CompanySession.startListening.
            CompanySession.shared.startListening(companyId: companyId)
            FeatureAccessManager.shared.bindToCompanySession()

            if let company {
                safePrint("🏢 CompanySession loaded: \(company.name) [\(company.subscriptionTier)/\(company.subscriptionStatus)] role=\(companyRole ?? "owner")")
            } else {
                safePrint("⚠️ CompanySession: companyId \(companyId) is set on the user but the company document couldn't be read (missing, or Firestore rules blocked it)")
            }

            if companyRole == "driver" {
                await bridgeDriverSession(companyId: companyId)
                return .driver
            }

            switch companyRole {
            case "manager": return .manager
            default: return .owner // "owner" or unrecognized - safest default within a company context
            }
        }

        CompanySession.shared.clear()
        return platformAdmin ? .owner : fallbackRole
    }

    /// Populates DriverSession.shared.driver from this account's own
    /// companies/{companyId}/drivers/{uid} record, creating it on
    /// first sign-in if it doesn't exist yet. The doc ID is always
    /// this account's own Firebase Auth uid (never an owner-chosen
    /// ID) so the Firestore rule allowing a driver to write only
    /// their own record has something stable to check against.
    /// Without this bridge, DriverTabView/DriverDashboardView have no
    /// way to know which driver just signed in.
    /// Called when "I also drive routes" is toggled on live (see
    /// SettingsView.setAlsoDrives) - the bridge above only ever ran
    /// once, during the initial sign-in flow, so without this,
    /// DriverSession stayed empty (driver dashboard stuck on "No
    /// driver profile loaded yet") until the whole app relaunched.
    func ensureDriverSessionBridged() async {
        guard let companyId = CompanySession.shared.currentCompanyId else { return }
        await bridgeDriverSession(companyId: companyId)
    }

    private func bridgeDriverSession(companyId: String) async {
        guard let uid = user?.uid else { return }
        let repo = FirestoreDriverRepository()

        if let existing = await repo.fetchDriver(uid: uid) {
            DriverSession.shared.setDriver(existing)
            return
        }

        let name = (user?.displayName?.isEmpty == false ? user?.displayName : nil)
            ?? user?.email
            ?? "New Driver"

        let newDriver = Driver(
            id: uid,
            name: name,
            phone: user?.phoneNumber,
            vehicle: ""
        )

        if let created = await repo.createDriver(newDriver) {
            DriverSession.shared.setDriver(created)
        } else {
            safePrint("⚠️ Could not create driver record for uid \(uid) in company \(companyId) - likely rules not yet updated to allow driver self-create (see firestore.rules.v4)")
        }
    }

    deinit {
        if let handle = authListener {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }
}
