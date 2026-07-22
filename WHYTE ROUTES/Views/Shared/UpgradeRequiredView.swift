import SwiftUI

// The "professional upgrade screen" a gated feature shows instead of
// silently doing nothing or crashing.
struct UpgradeRequiredView: View {

    let featureName: String
    let requiredTier: SubscriptionTier

    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 46))
                .foregroundColor(WRTheme.gold)

            Text(featureName)
                .font(.title2.bold())
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text("This feature requires the \(requiredTier.displayName) plan or higher.")
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showPaywall = true
            } label: {
                Text("Upgrade Plan")
                    .font(.headline)
                    .foregroundColor(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(WRTheme.gold)
                    .cornerRadius(12)
            }
            .padding(.top, 8)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WRTheme.gradient.ignoresSafeArea())
        .sheet(isPresented: $showPaywall) {
            SubscriptionTierView()
        }
    }
}
