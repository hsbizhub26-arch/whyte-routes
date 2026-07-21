import SwiftUI

struct LoginFlowView: View {

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false

    @EnvironmentObject var auth: AuthSession

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.07, green: 0.07, blue: 0.07)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 30) {

                Text(isSignUp ? "Create Account" : "Sign In")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .padding()
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(12)
                        .foregroundColor(.white)

                    SecureField("Password", text: $password)
                        .padding()
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                }
                .padding(.horizontal)

                Button {
                    Task {
                        if isSignUp {
                            try? await auth.signUp(email: email, password: password)
                        } else {
                            try? await auth.signIn(email: email, password: password)
                        }
                    }
                } label: {
                    Text(isSignUp ? "Create Account" : "Sign In")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.yellow.opacity(0.9))
                        .foregroundColor(.black)
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                Button {
                    isSignUp.toggle()
                } label: {
                    Text(isSignUp ?
                         "Already have an account? Sign In" :
                         "Don't have an account? Create one")
                        .foregroundColor(.yellow)
                        .font(.footnote)
                }

                if let error = auth.authError {
                    Text(error.localizedDescription)
                        .foregroundColor(.red)
                        .padding()
                }

                Spacer()
            }
            .padding(.top, 80)
        }
    }
}
