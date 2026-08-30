import Foundation
import FirebaseFirestore

/// A user's permissions as stored in Firestore at users/{uid}.
///
/// platformAdmin, companyId, and companyRole were added after role/
/// subscription/isAdmin were already live in production - all three
/// default safely when absent so existing documents keep working
/// unchanged. A user can be a platformAdmin AND belong to a company
/// (e.g. dogfooding your own platform as that company's owner) -
/// company-level permissions always come through companyRole/companyId,
/// never through platformAdmin.
struct UserPermissionsDocument {
    var role: UserRole
    var subscription: String
    var isAdmin: Bool

    /// True only for WHYTE ROUTES platform owners - manages all
    /// companies, subscriptions, and platform-wide settings.
    var platformAdmin: Bool

    /// Which company (tenant) this user belongs to, if any.
    var companyId: String?

    /// This user's role within companyId: "owner" | "manager" | "driver".
    var companyRole: String?

    /// Roles are permissions, not exclusive identities - owner-operators
    /// are a real, common WHYTE ROUTES customer (one person, one truck,
    /// dispatching AND driving). True means this owner/manager ALSO has
    /// a real companies/{id}/drivers/{uid} record and can access the
    /// driver experience alongside their admin tabs, not instead of them.
    /// Meaningless (ignored) when companyRole is already "driver" - a
    /// driver already has the full driver experience as their only view.
    var alsoDrives: Bool
}

/// Reads/writes the users/{uid} permissions document that is the
/// source of truth for role + subscription access.
final class UserPermissionsService {
    static let shared = UserPermissionsService()
    private init() {}

    private let db = Firestore.firestore()

    func fetch(uid: String) async -> UserPermissionsDocument? {
        do {
            let snapshot = try await db.collection("users").document(uid).getDocument()

            guard let data = snapshot.data(),
                  let roleRaw = data["role"] as? String,
                  let role = UserRole(rawValue: roleRaw)
            else {
                return nil
            }

            return UserPermissionsDocument(
                role: role,
                subscription: data["subscription"] as? String ?? "free",
                isAdmin: data["isAdmin"] as? Bool ?? false,
                platformAdmin: data["platformAdmin"] as? Bool ?? false,
                companyId: data["companyId"] as? String,
                companyRole: data["companyRole"] as? String,
                alsoDrives: data["alsoDrives"] as? Bool ?? false
            )
        } catch {
            // Missing document and read errors (offline, permission-denied)
            // are both handled the same way: fall back to the caller's
            // whitelist check rather than blocking access.
            print("⚠️ UserPermissionsService.fetch failed for \(uid): \(error.localizedDescription)")
            return nil
        }
    }

    /// Creates the permissions document only if one doesn't already exist -
    /// used to migrate whitelist-based accounts into real Firestore records
    /// the first time they sign in. Never blocks local access: the caller
    /// grants access from the whitelist check regardless of whether this
    /// write succeeds. Returns whether the document is confirmed to exist
    /// in Firestore (already there, or just created) so the caller can
    /// surface a real warning instead of failing silently.
    @discardableResult
    /// Polls users/{uid} from the SERVER (never the local cache -
    /// the cache would answer instantly and prove nothing) until it is
    /// readable, so callers know Security Rules can resolve this
    /// account's company membership before any company-scoped query.
    private func confirmServerVisible(_ docRef: DocumentReference) async {
        for attempt in 0..<4 {
            if let snapshot = try? await docRef.getDocument(source: .server), snapshot.exists {
                return
            }
            // 150ms, 300ms, 600ms, 1.2s - short enough not to be felt
            // on a normal sign-in, long enough to cover a slow one.
            let delay = UInt64(150_000_000) << attempt
            try? await Task.sleep(nanoseconds: delay)
        }
        print("⚠️ users/\(docRef.documentID) not server-visible yet - first queries may need a retry")
    }

    func createIfNeeded(
        uid: String,
        email: String,
        role: UserRole,
        subscription: String,
        isAdmin: Bool,
        platformAdmin: Bool = false,
        companyId: String? = nil,
        companyRole: String? = nil
    ) async -> Bool {
        let docRef = db.collection("users").document(uid)

        do {
            let existing = try await docRef.getDocument()
            if existing.exists { return true }

            var data: [String: Any] = [
                "uid": uid,
                "email": email,
                "role": role.rawValue,
                "subscription": subscription,
                "isAdmin": isAdmin,
                "platformAdmin": platformAdmin
            ]
            if let companyId { data["companyId"] = companyId }
            if let companyRole { data["companyRole"] = companyRole }

            try await docRef.setData(data)
            print("✅ Created users/\(uid) permissions document for \(email)")

            // The write is server-acknowledged by the line above, but
            // that is NOT the same as the Security Rules engine being
            // able to read it. Every company-scoped rule in this project
            // resolves membership with
            //   get(/databases/$(db)/documents/users/$(request.auth.uid))
            // and on the very first sign-in after an invite, the next
            // query can reach rule evaluation before that get() returns
            // the new document - which denies, because a missing key in
            // a rule is an evaluation error, not a false.
            //
            // The driver saw "Couldn't load your route. Missing or
            // insufficient permissions." on their first launch and a
            // clean load on the second. Confirmed by relaunching the
            // same account.
            //
            // So: don't return until a SERVER read succeeds. That is
            // the same path the rules engine takes, so once it answers,
            // membership is genuinely visible. Bounded - four tries over
            // roughly two seconds - and the write itself already
            // succeeded, so exhausting them still returns true rather
            // than failing a signup over a slow read.
            await confirmServerVisible(docRef)
            return true
        } catch {
            print("⚠️ Failed to create users/\(uid) permissions document: \(error.localizedDescription)")
            return false
        }
    }

    /// Merges new field values into an existing document without
    /// touching anything else already there - used to backfill
    /// platformAdmin/companyId/companyRole onto documents that were
    /// created before those fields existed.
    /// Attaches an existing, company-less account to a company after
    /// their invite finally arrived - see the late-invite path in
    /// AuthSession.
    ///
    /// Reports whether it actually succeeded, unlike backfillIfMissing,
    /// because the caller must not consume the invite on a failed
    /// write: burning it would leave the person locked out with no
    /// invite left to retry against, which is a worse version of the
    /// bug this exists to fix.
    ///
    /// The Firestore rule that permits this is the self-update branch,
    /// which freezes role/isAdmin/platformAdmin/subscription and, since
    /// the cross-tenant fix, companyId and companyRole too - so this
    /// write is allowed only where they are currently absent.
    func attachToCompany(uid: String, companyId: String, companyRole: String) async -> Bool {
        do {
            try await db.collection("users").document(uid).setData([
                "companyId": companyId,
                "companyRole": companyRole
            ], merge: true)
            return true
        } catch {
            print("⚠️ Failed attaching users/\(uid) to company \(companyId): \(error.localizedDescription)")
            return false
        }
    }

    func backfillIfMissing(uid: String, fields: [String: Any]) async {
        let docRef = db.collection("users").document(uid)
        do {
            try await docRef.setData(fields, merge: true)
        } catch {
            print("⚠️ Failed to backfill users/\(uid): \(error.localizedDescription)")
        }
    }
}
