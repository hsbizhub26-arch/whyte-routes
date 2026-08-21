import SwiftUI
import StoreKit

// The real paywall - replaces the old hardcoded mockup (static "$149/
// month" text, dead Subscribe button). Prices come live from StoreKit
// (purchaseManager.products), never hardcoded here, so they always
// match whatever's actually configured in App Store Connect. A
// purchase itself doesn't unlock anything client-side - it goes
// through PurchaseManager -> the syncSubscriptionEntitlement Cloud
// Function -> companies/{id}.subscriptionTier, which
// FeatureAccessManager (the real gate everywhere else in the app)
// reads. "Already active" here is judged against that same real tier,
// not against local purchase state, so it can't drift from what the
// rest of the app believes.
struct SubscriptionTierView: View {

    enum Tier: String, CaseIterable, Identifiable {
        case premium = "Premium"
        case premiumPlus = "Premium Plus"
        var id: String { rawValue }

        var monthlyProductID: String {
            self == .premium ? "whyteroutes.premium.monthly.v3" : "whyteroutes.premiumplus.monthly.v3"
        }
        var yearlyProductID: String {
            self == .premium ? "whyteroutes.premium.yearly.v3" : "whyteroutes.premiumplus.yearly.v3"
        }

        var features: [String] {
            switch self {
            case .premium:
                return [
                    "Live fleet map",
                    "Before/after proof of work",
                    "Route optimization",
                    "Up to 30 customers"
                ]
            case .premiumPlus:
                return [
                    "Everything in Premium",
                    "Driver performance & time reports",
                    "Advanced multi-driver dispatch",
                    "Unlimited customers"
                ]
            }
        }

        var requiredTier: SubscriptionTier {
            self == .premium ? .premium : .premiumPlus
        }
    }

    @EnvironmentObject var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTier: Tier = .premium

    private var currentTier: SubscriptionTier {
        FeatureAccessManager.shared.tier
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WRTheme.gradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        header
                        tierToggle
                        featureList

                        if currentTier >= selectedTier.requiredTier {
                            alreadyActiveBadge
                        } else {
                            pricingButtons
                        }

                        if let error = purchaseManager.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        restoreButton
                        legalFooter
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .task {
            if purchaseManager.products.isEmpty {
                await purchaseManager.fetchProducts()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("WHYTE ROUTES")
                .font(.title3.bold())
                .foregroundColor(WRTheme.gold)
            Text("Unlock full dispatch tools")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    private var tierToggle: some View {
        Picker("Tier", selection: $selectedTier) {
            ForEach(Tier.allCases) { tier in
                Text(tier.rawValue).tag(tier)
            }
        }
        .pickerStyle(.segmented)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(selectedTier.features, id: \.self) { feature in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WRTheme.gold)
                    Text(feature)
                        .foregroundColor(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.black.opacity(0.35))
        .cornerRadius(16)
    }

    private var monthlyProduct: Product? {
        purchaseManager.products.first { $0.id == selectedTier.monthlyProductID }
    }
    private var yearlyProduct: Product? {
        purchaseManager.products.first { $0.id == selectedTier.yearlyProductID }
    }

    private var pricingButtons: some View {
        VStack(spacing: 12) {
            if purchaseManager.products.isEmpty {
                ProgressView().tint(.white).padding()
            } else {
                if let yearly = yearlyProduct {
                    priceButton(product: yearly, badge: "Best value")
                }
                if let monthly = monthlyProduct {
                    priceButton(product: monthly, badge: nil)
                }
            }
        }
    }

    private func priceButton(product: Product, badge: String?) -> some View {
        Button {
            Task { await purchaseManager.purchase(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName.isEmpty ? product.description : product.displayName)
                        .font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.bold())
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.85))
                            .cornerRadius(6)
                    }
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.title3.bold())
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(WRTheme.gold)
            .foregroundColor(.black)
            .cornerRadius(14)
        }
        .disabled(purchaseManager.isPurchasing)
    }

    private var alreadyActiveBadge: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundColor(.green)
            Text("Your company is on the \(currentTier.displayName) plan.")
                .foregroundColor(.white)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            Task { await purchaseManager.restorePurchases() }
        }
        .foregroundColor(WRTheme.gold)
        .disabled(purchaseManager.isPurchasing)
    }

    private var legalFooter: some View {
        VStack(spacing: 6) {
            Text("Subscriptions are billed to your Apple ID and auto-renew unless canceled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple ID account settings.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Privacy Policy", destination: URL(string: "https://whyte-routes.web.app/privacy")!)
                Link("Terms of Use", destination: URL(string: "https://whyte-routes.web.app/terms")!)
            }
            .font(.caption2.bold())
            .foregroundColor(WRTheme.gold)
        }
        .padding(.top, 8)
    }
}
