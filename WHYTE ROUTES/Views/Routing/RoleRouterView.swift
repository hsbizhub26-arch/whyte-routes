import SwiftUI
import FirebaseAuth

/// Shown instead of the bare spinner when signing in has been resolving
/// for too long (see AuthSession.loadTimedOut). The original attempt keeps
/// running underneath, so this screen disappears on its own if it finishes.
private struct SlowConnectionView: View {
    let onRetry: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.07, green: 0.07, blue: 0.07)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color.yellow))
                    .scaleEffect(1.5)

                VStack(spacing: 8) {
                    Text("Still connecting…")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.white)
                    Text("This is taking longer than usual. Check your internet connection - we'll keep trying.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button(action: onRetry) {
                        Text("Try Again")
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.yellow)
                            .clipShape(Capsule())
                    }
                    Button("Sign Out", action: onSignOut)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.65))
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 32)
        }
    }
}

/// Routes the user to the correct part of the app based on auth + role.
struct RoleRouterView: View {

    @EnvironmentObject var auth: AuthSession
    @ObservedObject private var companySession = CompanySession.shared

    var body: some View {
        Group {
            if auth.isLoading {
                if auth.loadTimedOut {
                    SlowConnectionView(
                        onRetry: { auth.retryLoad() },
                        onSignOut: { try? Auth.auth().signOut() }
                    )
                } else {
                    LoadingScreen()
                }
            }
            else if auth.user == nil {
                OwnerLoginView()     // login screen
            }
            else {
                switch auth.role {

                case .owner:
                    if companySession.currentCompanyId == nil {
                        CreateCompanyView()   // self-serve signup with no company yet
                    } else {
                        OwnerTabView()        // business owner - full admin access
                    }

                case .manager:
                    ManagerTabView()     // dispatcher / supervisor

                case .driver:
                    DriverTabView()      // driver assigned routes / tracking

                case .none:
                    OwnerLoginView()     // should not happen, but safe fallback
                }
            }
        }
        .animation(.easeInOut, value: auth.role)
        .animation(.easeInOut, value: auth.user)
    }
}
