import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Runs a fresh Sign in with Apple purely to obtain a usable
/// authorization code, for account deletion.
///
/// Apple has required apps offering Sign in with Apple to REVOKE the
/// user's token when they delete their account since June 2022, and
/// App Review checks it as part of the 5.1.1(v) pass - otherwise the
/// app keeps appearing under "Apps Using Apple ID" in the user's
/// settings after they deleted the account.
///
/// Firebase's revokeToken(withAuthorizationCode:) needs an
/// authorization code, and the obvious shortcut - stash the one from
/// the original sign-in - does not work: those codes expire in minutes,
/// so by the time somebody deletes their account weeks later it is long
/// dead. A fresh authorization is the only reliable source.
///
/// It earns its keep twice over, because deleting a Firebase user often
/// fails with requiresRecentLogin, and this is exactly the recent login
/// that satisfies it.
@MainActor
final class AppleReauthenticator: NSObject {

    struct Credentials {
        let idToken: String
        let rawNonce: String
        let authorizationCode: String
    }

    enum ReauthError: LocalizedError {
        case cancelled
        case malformedCredential

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Apple sign-in was cancelled, so the account was not deleted."
            case .malformedCredential:
                return "Apple didn't return the information needed to delete this account. Please try again."
            }
        }
    }

    private var continuation: CheckedContinuation<Credentials, Error>?
    private var rawNonce: String?
    /// Keeps this object alive for the duration of the sheet - the
    /// system delegate reference is weak, and a controller whose
    /// delegate has been deallocated simply never calls back.
    private var selfRetain: AppleReauthenticator?

    func authenticate() async throws -> Credentials {
        let nonce = Self.randomNonceString()
        rawNonce = nonce
        selfRetain = self

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<Credentials, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        selfRetain = nil
    }

    // Same construction as the sign-in screen: Apple needs the nonce
    // sent with the request to be the SHA256 of the raw one, and
    // Firebase verifies the identity token against the raw value. That
    // pairing is what stops the token being replayed.
    private static func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

extension AppleReauthenticator: ASAuthorizationControllerDelegate {

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken,
              let idToken = String(data: identityToken, encoding: .utf8),
              // The piece the sign-in screen discards, and the only
              // reason this whole flow exists.
              let codeData = credential.authorizationCode,
              let authorizationCode = String(data: codeData, encoding: .utf8),
              let nonce = rawNonce
        else {
            finish(.failure(ReauthError.malformedCredential))
            return
        }

        finish(.success(Credentials(idToken: idToken,
                                    rawNonce: nonce,
                                    authorizationCode: authorizationCode)))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain,
           nsError.code == ASAuthorizationError.canceled.rawValue {
            finish(.failure(ReauthError.cancelled))
            return
        }
        finish(.failure(error))
    }
}

extension AppleReauthenticator: ASAuthorizationControllerPresentationContextProviding {

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? ASPresentationAnchor()
    }
}
