import SwiftUI

// The "professional upgrade screen" a gated feature shows instead of
// silently doing nothing or crashing. No purchase flow here - that's
// still out of scope (no StoreKit wiring yet, matches the standing
// "don't move into billing yet" instruction) - this explains the
// limit and stops here; upgrading itself is a conversation, not a
// button, until real billing exists.
struct UpgradeRequiredView: View {

    let featureName: String
    let requiredTier: SubscriptionTier

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

            Text("Contact WHYTE ROUTES to upgrade your plan and unlock this for your team.")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WRTheme.gradient.ignoresSafeArea())
    }
}
