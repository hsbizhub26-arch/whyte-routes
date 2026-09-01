import Foundation
import FirebaseFirestore

final class InviteRepository {

    private let db = Firestore.firestore()
    private let defaultValidityDays = 14

    // MARK: - Owner: create an invite

    func createInvite(
        companyId: String,
        companyName: String,
        contactMethod: String,
        contactValue: String,
        role: String,
        invitedByUID: String,
        completion: @escaping (Result<Invite, Error>) -> Void
    ) {
        let normalized = Invite.normalize(contactValue, method: contactMethod)
        guard !normalized.isEmpty else {
            completion(.failure(NSError(domain: "InviteRepository", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid \(contactMethod == "email" ? "email address" : "phone number")."])))
            return
        }

        let now = Date()
        let invite = Invite(
            id: normalized,
            companyId: companyId,
            companyName: companyName,
            contactMethod: contactMethod,
            role: role,
            status: "pending",
            invitedByUID: invitedByUID,
            createdAt: now,
            expiresAt: Calendar.current.date(byAdding: .day, value: defaultValidityDays, to: now) ?? now
        )

        db.collection("invites").document(normalized).setData(invite.toDict()) { error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(invite))
            }
        }
    }

    // MARK: - Owner: pending invites list

    func listenToPendingInvites(companyId: String, handler: @escaping ([Invite]) -> Void) {
        db.collection("invites")
            .whereField("companyId", isEqualTo: companyId)
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { snapshot, error in
                guard error == nil else {
                    print("❌ Failed to listen to invites:", error?.localizedDescription ?? "")
                    handler([])
                    return
                }
                let invites: [Invite] = snapshot?.documents.compactMap { doc in
                    Invite(from: doc.data(), id: doc.documentID)
                } ?? []
                handler(invites)
            }
    }

    // MARK: - Owner: cancel an invite

    func cancelInvite(id: String, completion: ((Bool) -> Void)? = nil) {
        db.collection("invites").document(id).updateData(["status": "cancelled"]) { error in
            completion?(error == nil)
        }
    }

    // MARK: - Sign-in flow: look up + consume an invite for the signing-in user

    /// Looks up a pending, unexpired invite for this exact contact value.
    /// Never a query - always a direct-ID get, which is what makes the
    /// security rule safe (a user can only ever fetch the one invite
    /// matching their own verified sign-in identity).
    func lookupInvite(contactValue: String, method: String) async -> Invite? {
        let normalized = Invite.normalize(contactValue, method: method)
        guard !normalized.isEmpty else { return nil }

        do {
            let snapshot = try await db.collection("invites").document(normalized).getDocument()
            guard let data = snapshot.data(), let invite = Invite(from: data, id: snapshot.documentID) else {
                return nil
            }
            return invite.isUsable ? invite : nil
        } catch {
            print("⚠️ InviteRepository.lookupInvite(\(method)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func consume(_ invite: Invite) async -> Bool {
        do {
            try await db.collection("invites").document(invite.id).updateData(["status": "accepted"])
            return true
        } catch {
            // invite.id IS the normalized email address or E.164
            // phone number - that is the entire design of the invites
            // collection (see Invite.normalize). Logging the id is
            // logging the person. lookupInvite above stays a plain
            // print because it deliberately logs only the *method*
            // ("email"/"phone"), never the value itself.
            safePrint("⚠️ InviteRepository.consume(\(invite.id)) failed: \(error.localizedDescription)")
            return false
        }
    }
}
