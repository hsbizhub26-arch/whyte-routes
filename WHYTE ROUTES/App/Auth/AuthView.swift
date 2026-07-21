import SwiftUI

struct AuthView: View {

    @EnvironmentObject var auth: AuthSession
    @State private var email = ""
    @State private var password = ""
    @State private var mode: AuthMode = .signIn
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 30) {

            Text(mode == .signIn ? "Sign In" : "Create Account")
                .font(.largeTitle.bold())
                .foregroundColor(.yellow)

            TextField("Email", text: $email)
                .padding()
                .background(Color.white.opacity(0.1))
                .foregroundColor(.white)
                .cornerRadius(12)
                .textInputAutocapitalization(.never)

            SecureField("Password", text: $password)
                .padding()
                .background(Color.white.opacity(0.1))
                .foregroundColor(.white)
                .cornerRadius(12)

            Button(mode == .signIn ? "Sign In" : "Sign Up") {
                Task { await handleAuth() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button(
                "Switch to \(mode == .signIn ? "Sign Up" : "Sign In")"
            ) { mode.toggle() }
            .foregroundColor(.yellow)

        }
        .padding()
        .background(Color.black.ignoresSafeArea())
    }

    func handleAuth() async {
        do {
            if mode == .signIn {
                try await auth.signIn(email: email, password: password)
            } else {
                try await auth.signUp(email: email, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum AuthMode { case signIn, signUp
    mutating func toggle() { self = (self == .signIn ? .signUp : .signIn) }
}
