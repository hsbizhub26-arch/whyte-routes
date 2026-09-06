import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import Combine

/// Account deletion, as App Store Guideline 5.1.1(v) requires it: the
/// account AND the personal data that hangs off it, actually gone.
///
/// The previous implementation reported success on a deletion that had
/// largely not happened. It issued the Firestore writes inside bare
/// `catch { }` blocks, so every failure was discarded silently; the
/// users/{uid} delete was in fact being REFUSED, because no rule
/// permitted it. Execution continued regardless, the Auth user was
/// deleted, and the UI cleared its error and said it was done - while
/// the row holding the person's email, role and company membership
/// stayed in Firestore permanently, now with no signed-in identity left
/// that could ever remove it. It also targeted users/{uid}/sessions and
/// users/{uid}/data, two subcollections this app has never had.
///
/// The rules for both users/{uid} and a driver's own record now allow
/// self-deletion, and nothing here is swallowed: if the data cleanup
/// fails, the Auth account is left ALONE and the user is told. Deleting
/// the login while the data survives is the one outcome worse than
/// failing outright, because it strands the data beyond anyone's reach.
final class DeleteAccountManager: ObservableObject {
    @Published var isDeleting: Bool = false
    @Published var errorMessage: String?

    func deleteCurrentUser(password: String? = nil) async {
        await MainActor.run {
            self.isDeleting = true
            self.errorMessage = nil
        }

        guard let user = Auth.auth().currentUser else {
            await MainActor.run {
                self.errorMessage = "No signed-in user."
                self.isDeleting = false
            }
            return
        }

        let uid = user.uid
        let companyId = CompanySession.shared.currentCompanyId

        // Apple first, before anything irreversible: this re-authorises
        // the user (which is also what satisfies requiresRecentLogin on
        // the delete below) and yields the authorization code needed to
        // revoke their token. If they cancel the sheet, nothing has
        // happened yet and we can stop cleanly.
        var appleAuthorizationCode: String?
        if user.providerData.contains(where: { $0.providerID == "apple.com" }) {
            do {
                let credentials = try await AppleReauthenticator().authenticate()
                let credential = OAuthProvider.appleCredential(
                    withIDToken: credentials.idToken,
                    rawNonce: credentials.rawNonce,
                    fullName: nil
                )
                try await user.reauthenticate(with: credential)
                appleAuthorizationCode = credentials.authorizationCode
            } catch {
                await MainActor.run {
                    self.errorMessage = Self.friendlyErrorMessage(from: error)
                    self.isDeleting = false
                }
                return
            }
        }

        // Email/password accounts get the same identity re-check the
        // Apple sheet gives Apple users - re-enter the password before
        // anything irreversible. Without it, an unlocked phone left on
        // this screen could delete the account with two taps and no
        // proof it was the owner doing it.
        if user.providerData.contains(where: { $0.providerID == "password" }) {
            guard let password, !password.isEmpty, let email = user.email else {
                await MainActor.run {
                    self.errorMessage = "Enter your password to confirm deletion."
                    self.isDeleting = false
                }
                return
            }
            do {
                let credential = EmailAuthProvider.credential(withEmail: email, password: password)
                try await user.reauthenticate(with: credential)
            } catch {
                await MainActor.run {
                    self.errorMessage = "That password didn't match. Your account was not deleted."
                    self.isDeleting = false
                }
                return
            }
        }

        do {
            // Order matters. Everything company-scoped goes first,
            // because the rules that authorise those deletes resolve
            // the caller's company THROUGH users/{uid} - remove that
            // row first and the driver record becomes undeletable.
            if let companyId {
                try await deleteDriverRecord(uid: uid, companyId: companyId)
            }
            try await Firestore.firestore().collection("users").document(uid).delete()
        } catch {
            await MainActor.run {
                self.errorMessage = "Couldn't delete your data, so your account has been left signed in and intact. Please try again, or contact support. (\(error.localizedDescription))"
                self.isDeleting = false
            }
            return
        }

        // The data is gone; now sever Apple's side before removing the
        // login. A failure here is logged rather than fatal - refusing
        // to delete the account at this point would leave the user with
        // their data already erased and their login still standing,
        // which is worse than an un-revoked token.
        if let appleAuthorizationCode {
            do {
                try await Auth.auth().revokeToken(withAuthorizationCode: appleAuthorizationCode)
            } catch {
                print("⚠️ Apple token revocation failed: \(error.localizedDescription)")
            }
        }

        do {
            try await user.delete()
            await MainActor.run {
                self.errorMessage = nil
                self.isDeleting = false
            }
        } catch {
            await MainActor.run {
                self.handleDeletionError(error)
                self.isDeleting = false
            }
        }
    }

    /// The driver record and the government ID attached to it.
    ///
    /// The licence photo is deleted from Storage BEFORE the record that
    /// points at it, since the path only exists on that document - drop
    /// the document first and the image is orphaned in a bucket with
    /// nothing left referencing it. A photo that was already missing is
    /// not an error; anything else is.
    private func deleteDriverRecord(uid: String, companyId: String) async throws {
        let driverRef = Firestore.firestore()
            .collection("companies").document(companyId)
            .collection("drivers").document(uid)

        let snapshot = try await driverRef.getDocument()
        guard snapshot.exists else { return }

        if let path = snapshot.data()?["licensePhotoPath"] as? String, !path.isEmpty {
            do {
                try await Storage.storage().reference().child(path).delete()
            } catch {
                let nsError = error as NSError
                let alreadyGone = nsError.domain == StorageErrorDomain
                    && nsError.code == StorageErrorCode.objectNotFound.rawValue
                if !alreadyGone { throw error }
            }
        }

        try await driverRef.delete()
    }

    private func handleDeletionError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           let authError = AuthErrorCode(_bridgedNSError: nsError),
           authError == .requiresRecentLogin {
            self.errorMessage = "Please sign in again to delete your account."
            return
        }
        self.errorMessage = Self.friendlyErrorMessage(from: error)
    }

    private static func friendlyErrorMessage(from error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           let authError = AuthErrorCode(_bridgedNSError: nsError) {
            switch authError {
            case .networkError:
                return "Network error occurred. Please check your connection."
            case .userDisabled:
                return "Your account has been disabled."
            case .wrongPassword:
                return "Incorrect password."
            case .tooManyRequests:
                return "Too many requests. Please try again later."
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
