import SwiftUI
import FirebaseAuth
import AuthenticationServices
import CryptoKit
import GoogleSignIn

struct OwnerLoginView: View {

    // MARK: - State
    @State private var email = ""
    @State private var password = ""
    @State private var error = ""

    @State private var isSecure = true
    @State private var isLoading = false
    @State private var isSignUp = false

    @State private var rememberMe = false
    @State private var showingResetAlert = false
    @State private var resetInfo: String = ""
    @State private var currentAppleNonce: String?

    // MARK: - Body
    var body: some View {
        NavigationStack {
            ZStack {
                WRTheme.gradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {

                        header
                        formFields

                        Toggle(isOn: $rememberMe) {
                            Text("Remember me")
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .toggleStyle(SwitchToggleStyle(tint: WRTheme.gold))
                        .padding(.horizontal)

                        if !error.isEmpty {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }

                        if !isSignUp { forgotPassword }

                        Button {
                            isSignUp ? createAccount() : login()
                        } label: {
                            Text(buttonTitle)
                                .fontWeight(.bold)
                        }
                        .buttonStyle(GoldButtonStyle())
                        .padding(.horizontal)
                        .disabled(!isFormValid || isLoading)
                        .opacity(!isFormValid || isLoading ? 0.6 : 1)

                        Button {
                            isSignUp.toggle()
                            error = ""
                        } label: {
                            Text(isSignUp ?
                                 "Already have an account? Sign in" :
                                 "Don't have an account? Create one")
                                .font(.footnote)
                                .foregroundColor(WRTheme.gold)
                        }

                        divider
                        ssoButtons

                        Spacer(minLength: 16)
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .onAppear {
            if let saved = getRememberedEmail() {
                email = saved
                rememberMe = true
            }
        }
        .alert("Password Reset", isPresented: $showingResetAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(resetInfo)
        }
    }
}

// MARK: - Subviews
extension OwnerLoginView {

    var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "map.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundColor(WRTheme.gold)

            Text(isSignUp ? "CREATE ACCOUNT" : "SIGN IN")
                .foregroundColor(WRTheme.gold)
                .font(.largeTitle.bold())

            Text(isSignUp
                 ? "Starting a new company, or joining one you were invited to"
                 : "Sign in to Whyte Routes")
                .foregroundColor(.white.opacity(0.7))
                .font(.subheadline)
        }
        .padding(.top, 8)
    }

    var formFields: some View {
        VStack(spacing: 16) {
            emailField
            passwordField
        }
        .padding(.horizontal)
    }

    var emailField: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .foregroundColor(.white.opacity(0.7))

            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundColor(.white)
        }
        .padding()
        .background(Color.gray.opacity(0.4))
        .cornerRadius(14)
    }

    var passwordField: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .foregroundColor(.white.opacity(0.7))

            Group {
                if isSecure {
                    SecureField("Password", text: $password)
                } else {
                    TextField("Password", text: $password)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundColor(.white)

            Button {
                isSecure.toggle()
            } label: {
                Image(systemName: isSecure ? "eye.slash" : "eye")
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding()
        .background(Color.gray.opacity(0.4))
        .cornerRadius(14)
    }

    var forgotPassword: some View {
        HStack {
            Spacer()
            Button("Forgot password?") {
                guard isValidEmail(email) else {
                    resetInfo = "Please enter a valid email."
                    showingResetAlert = true
                    return
                }
                Auth.auth().sendPasswordReset(withEmail: email) { err in
                    DispatchQueue.main.async {
                        if let err = err as NSError? {
                            if err.domain == "FIRAuthErrorDomain" {
                                switch err.code {
                                case 17008:
                                    resetInfo = "The email address you entered is invalid."
                                case 17011:
                                    resetInfo = "No account found with that email address."
                                default:
                                    resetInfo = "Couldn't send the reset email. Please try again."
                                }
                            } else {
                                resetInfo = "Couldn't send the reset email. Please try again."
                            }
                        } else {
                            resetInfo = "Password reset email sent to \(email)."
                        }
                        showingResetAlert = true
                    }
                }
            }
            .font(.footnote)
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal)
        }
    }

    var divider: some View {
        HStack {
            Rectangle().frame(height: 1).foregroundColor(.white.opacity(0.15))
            Text("or continue with")
                .foregroundColor(.white.opacity(0.7))
                .font(.footnote)
            Rectangle().frame(height: 1).foregroundColor(.white.opacity(0.15))
        }
        .padding(.horizontal)
    }

    var ssoButtons: some View {
        HStack(spacing: 12) {

            SignInWithAppleButton(.signIn) { request in
                let nonce = randomNonceString()
                currentAppleNonce = nonce
                request.requestedScopes = [.fullName, .email]
                request.nonce = sha256(nonce)
            } onCompletion: { result in
                handleAppleSignInResult(result)
            }
            .signInWithAppleButtonStyle(.whiteOutline)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(WRTheme.gold.opacity(0.35), lineWidth: 1)
            )
            .disabled(isLoading)

            Button {
                signInWithGoogle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "g.circle.fill")
                    Text("Google")
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.6))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(WRTheme.gold.opacity(0.35), lineWidth: 1)
                )
            }
            .disabled(isLoading)
        }
        .padding(.horizontal)
    }
}

// MARK: - Logic
extension OwnerLoginView {

    var isFormValid: Bool {
        isValidEmail(email) && !password.isEmpty
    }

    var buttonTitle: String {
        if isSignUp { return isLoading ? "CREATING ACCOUNT…" : "CREATE ACCOUNT" }
        return isLoading ? "SIGNING IN…" : "LOGIN"
    }

    func isValidEmail(_ value: String) -> Bool {
        value.contains("@") && value.contains(".") && value.count > 5
    }

    func login() {
        guard isFormValid else {
            error = "Please enter a valid email and password."
            return
        }

        error = ""
        isLoading = true

        Task {
            defer { isLoading = false }

            do {
                _ = try await Auth.auth().signIn(withEmail: email, password: password)
                saveRememberedEmail(rememberMe ? email : nil)
            } catch let authError {
                let nsError = authError as NSError
                print("⛔️ Sign-in failed: domain=\(nsError.domain) code=\(nsError.code)")
                // domain and code above ship - they are what makes
                // a field report actionable. userInfo does not:
                // FirebaseAuth puts FIRAuthErrorUserInfoEmailKey in
                // there, and on some failures the raw Identity
                // Toolkit response body, so this dump can carry the
                // address the user just typed. Same for the
                // underlying error below.
                safePrint("⛔️ userInfo=\(nsError.userInfo)")
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    safePrint("⛔️ underlying: domain=\(underlying.domain) code=\(underlying.code) userInfo=\(underlying.userInfo)")
                }
                self.error = friendlyAuthMessage(authError)
            }
        }
    }

    // Firebase's own error strings are written for developers, and
    // they were going straight onto the sign-in screen. Typing your
    // password wrong produced "The supplied auth credential is
    // malformed or has expired." - which tells a contractor standing
    // in a driveway at 5am nothing at all, and reads like the app is
    // broken rather than like they made a typo.
    //
    // wrongPassword, userNotFound and invalidCredential deliberately
    // collapse into ONE message. Distinguishing them would turn the
    // login form into an oracle for which email addresses have
    // accounts, which is worth more to someone probing the app than
    // the small convenience is worth to a real user.
    private func friendlyAuthMessage(_ error: Error) -> String {
        let nsError = error as NSError

        // Firebase's backend collapses "no such account" and "wrong
        // password" into one INVALID_LOGIN_CREDENTIALS response - that
        // is email-enumeration protection doing its job - and the SDK
        // does not reliably surface it as a code this switch knows.
        // Matched on the MESSAGE before the code lookup, because when
        // it arrives as .internalError the code tells us nothing and
        // the message tells us everything.
        let raw = "\(nsError.userInfo[NSLocalizedFailureReasonErrorKey] ?? "") \(nsError.localizedDescription)"
        if raw.contains("INVALID_LOGIN_CREDENTIALS")
            || raw.contains("INVALID_PASSWORD")
            || raw.contains("EMAIL_NOT_FOUND") {
            return "Incorrect email or password."
        }

        guard nsError.domain == AuthErrorDomain,
              let code = AuthErrorCode(rawValue: nsError.code) else {
            // The code goes ON SCREEN for anything genuinely unmapped.
            // The first version of this function swallowed it, which
            // turned a diagnosable failure into "Something went wrong"
            // and cost an afternoon of guessing. A short code in
            // brackets means nothing to a customer and is decisive to
            // whoever they show the screen to.
            return "Something went wrong. Please try again. (\(nsError.domain) \(nsError.code))"
        }

        switch code {
        case .wrongPassword, .userNotFound, .invalidCredential, .invalidEmail:
            return "Incorrect email or password."
        case .userDisabled:
            return "This account has been disabled. Contact your company owner."
        case .emailAlreadyInUse:
            return "That email already has an account - try signing in instead."
        case .weakPassword:
            return "Choose a password at least 6 characters long."
        case .networkError:
            return "Can't reach the server - check your connection and try again."
        case .tooManyRequests:
            return "Too many attempts. Wait a minute and try again."
        case .keychainError:
            // Not a credential problem at all - the sign-in SUCCEEDED
            // and then failed writing the session to the device
            // keychain. Worth its own message because every other
            // wording sends the user off to re-check a password that
            // was never wrong.
            return "Signed in, but this device wouldn't save the session. Restart the app and try again."
        default:
            return "Something went wrong. Please try again. (code \(nsError.code))"
        }
    }

    // Account creation is intentionally generic - not "sign up as a
    // driver" or "as an owner". What happens next is decided entirely
    // by AuthSession.listenForAuthChanges() once this succeeds: a
    // pending invite for this email attaches them to that company/role,
    // a platform-admin UID bootstraps as owner, otherwise they land as
    // a company-less driver until an owner invites them. Nothing here
    // needs to know which case applies.
    func createAccount() {
        guard isFormValid else {
            error = "Please enter a valid email and password."
            return
        }

        error = ""
        isLoading = true

        Task {
            defer { isLoading = false }

            do {
                _ = try await Auth.auth().createUser(withEmail: email, password: password)
                saveRememberedEmail(rememberMe ? email : nil)
            } catch let authError {
                let nsError = authError as NSError
                print("⛔️ Account creation failed: domain=\(nsError.domain) code=\(nsError.code)")
                self.error = friendlyAuthMessage(authError)
            }
        }
    }

    func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentAppleNonce,
                  let identityToken = credential.identityToken,
                  let idTokenString = String(data: identityToken, encoding: .utf8) else {
                error = "Apple sign-in failed. Please try again."
                return
            }

            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: nonce,
                fullName: credential.fullName
            )

            error = ""
            isLoading = true
            Task {
                defer { isLoading = false }
                do {
                    _ = try await Auth.auth().signIn(with: firebaseCredential)
                } catch let authError {
                    self.error = friendlyAuthMessage(authError)
                }
            }

        case .failure(let authError):
            // User cancelling the Apple sign-in sheet isn't a real error.
            let nsError = authError as NSError
            if nsError.code != ASAuthorizationError.canceled.rawValue {
                error = "Couldn't finish signing in with Apple. Please try again."
            }
        }
    }

    // Apple requires the nonce sent with the sign-in request to be
    // rehashed (SHA256) before Firebase can verify the identity token
    // against it - this pairing is what prevents replay attacks.
    func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    func signInWithGoogle() {
        guard let presentingVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first?.rootViewController else {
            error = "Unable to present Google sign-in."
            return
        }

        error = ""
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingVC)
                guard let idToken = result.user.idToken?.tokenString else {
                    self.error = "Google sign-in failed. Please try again."
                    return
                }
                let credential = GoogleAuthProvider.credential(
                    withIDToken: idToken,
                    accessToken: result.user.accessToken.tokenString
                )
                _ = try await Auth.auth().signIn(with: credential)
            } catch let signInError {
                let nsError = signInError as NSError
                // User cancelling the Google sign-in sheet isn't a real error.
                if nsError.domain == "com.google.GIDSignIn", nsError.code == GIDSignInError.canceled.rawValue {
                    return
                }
                self.error = self.friendlyAuthMessage(signInError)
            }
        }
    }

    func saveRememberedEmail(_ value: String?) {
        if let value {
            UserDefaults.standard.set(value, forKey: "WRRememberedEmail")
        } else {
            UserDefaults.standard.removeObject(forKey: "WRRememberedEmail")
        }
    }

    func getRememberedEmail() -> String? {
        UserDefaults.standard.string(forKey: "WRRememberedEmail")
    }
}
