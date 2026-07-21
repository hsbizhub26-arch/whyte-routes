//
//  SubscriptionGate.swift
//  WHYTE ROUTES
//

import SwiftUI

/// Blocks content unless user has Premium or Premium Plus.
/// Routes to PaywallView if not subscribed.
struct SubscriptionGate<Content: View>: View {
    @EnvironmentObject var purchaseManager: PurchaseManager
    @EnvironmentObject var entitlements: AppEntitlements

    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        Group {
            if entitlements.isPremiumUnlocked ||
               entitlements.isPremiumPlusUnlocked ||
               purchaseManager.hasPremiumAccess {

                content()

            } else {
                PaywallView()
            }
        }
    }
}
