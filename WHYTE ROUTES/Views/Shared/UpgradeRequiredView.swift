import SwiftUI

// The "professional upgrade screen" a gated feature shows instead of
// silently doing nothing or crashing.
struct UpgradeRequiredView: View {

    let featureName: String
    let requiredTier: SubscriptionTier

    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false

    // A DEAD END until now. This is a bare VStack, shown as a sheet
    // from five different gated features, with no navigation bar and
    // no dismiss of its own - and a sheet's swipe-down is unreliable
    // over full-bleed content. Someone who hit their customer limit
    // got a padlock they could not get out of, and force-quitting was
    // the only way back into the app.
    //
    // Same defect the driver's route, stop and profile sheets had.
    // Worth stating plainly: three separate screens in this app
    // shipped as traps, which means the pattern - present a bare view
    // as a sheet and assume the swipe covers it - is the thing to
    // watch for, not any one of them.
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "chevron.down")
                        .font(.body.weight(.semibold))
                        .foregroundColor(WRTheme.gold)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)

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
