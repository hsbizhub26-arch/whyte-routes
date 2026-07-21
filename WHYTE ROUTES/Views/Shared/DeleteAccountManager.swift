import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import Combine

final class DeleteAccountManager: ObservableObject {
    @Published var isDeleting: Bool = false
    @Published var errorMessage: String?

    func deleteCurrentUser() async {
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
        let db = Firestore.firestore()

        // Delete user document
        do {
            let userDocRef = db.collection("users").document(uid)
            let userDocSnapshot = try await userDocRef.getDocument()
            if userDocSnapshot.exists {
                try await userDocRef.delete()
            }
        } catch { }

        // Delete sessions
        do {
            let sessionsSnapshot = try await db.collection("users").document(uid)
                .collection("sessions").getDocuments()

            for doc in sessionsSnapshot.documents {
                try? await doc.reference.delete()
            }
        } catch { }

        // Delete data
        do {
            let dataSnapshot = try await db.collection("users").document(uid)
                .collection("data").getDocuments()

            for doc in dataSnapshot.documents {
                try? await doc.reference.delete()
            }
        } catch { }

        // Delete Auth user
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

    func deleteCurrentUser(completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                try await self.deleteCurrentUser()
                await MainActor.run { completion(.success(())) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
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

