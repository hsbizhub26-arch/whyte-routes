import SwiftUI

struct PremiumFeatureGuard<Content: View>: View {
    let allowed: Bool
    let content: () -> Content

    var body: some View {
        if allowed {
            content()
        } else {
            SubscriptionGate() // your paywall view
        }
    }
}
