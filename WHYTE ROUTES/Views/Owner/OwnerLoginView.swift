import SwiftUI
import FirebaseAuth
import AuthenticationServices

struct OwnerLoginView: View {

    // MARK: - State
    @State private var email = ""
    @State private var password = ""
    @State private var error = ""

    @State private var isSecure = true
    @State private var isLoading = false

    @State private var rememberMe = false
    @State private var showingResetAlert = false
    @State private var resetInfo: String = ""

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

                        forgotPassword

                        Button {
                            login()
                        } label: {
                            Text(isLoading ? "SIGNING IN…" : "LOGIN")
                                .fontWeight(.bold)
                        }
                        .buttonStyle(GoldButtonStyle())
                        .padding(.horizontal)
                        .disabled(!isFormValid || isLoading)
                        .opacity(!isFormValid || isLoading ? 0.6 : 1)

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

            Text("ADMIN LOGIN")
                .foregroundColor(WRTheme.gold)
                .font(.largeTitle.bold())

            Text("Sign in to manage Whyte Routes")
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
                                    resetInfo = err.localizedDescription
                                }
                            } else {
                                resetInfo = err.localizedDescription
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

            VStack(spacing: 4) {
                SignInWithAppleButton(.signIn) { _ in } onCompletion: { _ in }
                    .signInWithAppleButtonStyle(.whiteOutline)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(WRTheme.gold.opacity(0.35), lineWidth: 1)
                    )
                    .opacity(0.4)
                    .allowsHitTesting(false)

                Text("Not yet available")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                Button {
                    // Disabled
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
                .opacity(0.4)
                .disabled(true)

                Text("Not yet available")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
    }
}

// MARK: - Logic
extension OwnerLoginView {

    var isFormValid: Bool {
        isValidEmail(email) && !password.isEmpty
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
                print("⛔️ userInfo=\(nsError.userInfo)")
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("⛔️ underlying: domain=\(underlying.domain) code=\(underlying.code) userInfo=\(underlying.userInfo)")
                }
                self.error = authError.localizedDescription
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
