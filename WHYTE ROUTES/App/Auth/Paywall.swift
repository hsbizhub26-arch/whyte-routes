//
//  Paywall.swift
//  WHYTE ROUTES
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var purchaseManager: PurchaseManager
    @EnvironmentObject var entitlements: AppEntitlements
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.07, green: 0.07, blue: 0.07)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {

                    // Already subscribed to Premium or Premium+?
                    if entitlements.isPremiumUnlocked || entitlements.isPremiumPlusUnlocked {
                        alreadyUnlockedMessage
                    } else {
                        paywallContent
                    }
                }
                .padding(.vertical, 40)
            }
        }
    }

    // MARK: - Already Subscribed Message
    private var alreadyUnlockedMessage: some View {
        VStack(spacing: 12) {
            Text("Your subscription is already active.")
                .font(.headline)
                .foregroundColor(.green)
                .padding(.horizontal)

            if entitlements.isPremiumPlusUnlocked {
                Text("Premium Plus Unlocked")
                    .font(.title3.bold())
                    .foregroundColor(.yellow)
            } else if entitlements.isPremiumUnlocked {
                Text("Premium Unlocked")
                    .font(.title3.bold())
                    .foregroundColor(.yellow)
            }
        }
    }

    // MARK: - Paywall Content
    private var paywallContent: some View {
        VStack(spacing: 30) {

            Image("whyteroutes_logo")
                .resizable()
                .scaledToFit()
                .frame(width: 140)

            Text("Unlock WHYTE ROUTES")
                .font(.largeTitle.bold())
                .foregroundColor(.white)

            Text("Full dispatch. Multi-driver mode. Live GPS tracking.\nManager dashboard. Priority routing.")
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal)

            VStack(spacing: 16) {
                ForEach(purchaseManager.products, id: \.id) { product in
                    PaywallCard(product: product) {
                        purchaseManager.purchase(product)
                    }
                }
            }
            .padding(.horizontal)

            Button("Restore Purchases") {
                purchaseManager.restorePurchases()
            }
            .foregroundColor(.gold)
            .padding(.top, 20)
        }
    }
}

// MARK: - Gold Color (Safe to leave here)
extension Color {
    static let gold = Color(red: 0.91, green: 0.76, blue: 0.34)
}

// MARK: - Individual Paywall Product Card
struct PaywallCard: View {
    let product: Product
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {

                Text(product.displayName)
                    .font(.title2.bold())
                    .foregroundColor(.white)

                Text(product.description)
                    .foregroundColor(.gray)

                Text(product.displayPrice)
                    .font(.title.bold())
                    .foregroundColor(.gold)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.45))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gold, lineWidth: 1)
            )
        }
    }
}
