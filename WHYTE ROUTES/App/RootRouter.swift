import SwiftUI
import FirebaseAuth

struct RootRouter: View {

    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var entitlements: AppEntitlements

    var body: some View {
        Group {
            if auth.user == nil {
                AuthView()   // login/signup
            } else {
                MainAppRouter()
            }
        }
    }
}

struct AuthView: View {
    @EnvironmentObject private var authSession: AuthSession

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign In")
                .font(.largeTitle)

            TextField("Email", text: $email)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

            SecureField("Password", text: $password)
                .textContentType(.password)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button(action: signIn) {
                if isLoading {
                    ProgressView()
                } else {
                    Text("Sign In")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || email.isEmpty || password.isEmpty)
        }
        .padding()
    }

    private func signIn() {
        isLoading = true
        errorMessage = nil
        Auth.auth().signIn(withEmail: email, password: password) { _, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    self.errorMessage = error.localizedDescription
                } else {
                    // AuthSession listener will update app state
                    self.authSession.listenForAuthChanges()
                }
            }
        }
    }
}

struct MainAppRouter: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var entitlements: AppEntitlements

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    HStack {
                        Text("User ID")
                        Spacer()
                        Text(auth.user?.uid ?? "unknown")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Role")
                        Spacer()
                        Text(String(describing: auth.role))
                            .foregroundStyle(.secondary)
                    }
                    Button("Sign Out", role: .destructive) {
                        signOut()
                    }
                }

                Section("Entitlements") {
                    HStack {
                        Text("Premium")
                        Spacer()
                        Image(systemName: entitlements.premiumUnlocked ? "checkmark.seal.fill" : "xmark.seal")
                            .foregroundStyle(entitlements.premiumUnlocked ? .green : .secondary)
                    }
                    HStack {
                        Text("Premium Plus")
                        Spacer()
                        Image(systemName: entitlements.premiumPlusUnlocked ? "checkmark.seal.fill" : "xmark.seal")
                            .foregroundStyle(entitlements.premiumPlusUnlocked ? .green : .secondary)
                    }
                }
            }
            .navigationTitle("WHYTE ROUTES")
        }
    }

    private func signOut() {
        do {
            try Auth.auth().signOut()
        } catch {
            // Handle sign-out error if desired
        }
    }
}
