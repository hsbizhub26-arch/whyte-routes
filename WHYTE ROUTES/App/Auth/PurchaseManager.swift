//
//  PurchaseManager.swift
//  WHYTE ROUTES
//
//  Real StoreKit2 subscription flow. The client never grants itself a
//  tier directly - Firestore rules only allow a platform admin to
//  write companies/{id}.subscriptionTier, on purpose, so a purchase
//  here doesn't unlock anything by itself. Every verified transaction
//  gets sent (as its raw signed JWS) to the syncSubscriptionEntitlement
//  Cloud Function, which independently re-verifies it with Apple's
//  App Store Server API before writing the tier with Admin SDK trust.
//  FeatureAccessManager picks the new tier up automatically once that
//  write lands - this class only drives the purchase UI, it is not
//  itself a source of feature access.

import Foundation
import Combine
import StoreKit
import FirebaseFunctions

@MainActor
final class PurchaseManager: ObservableObject {

    // MARK: - Product IDs (MUST match App Store Connect / WhyteRoutes.storekit)
    static let productIDs: Set<String> = [
        "whyteroutes.premium.monthly.v3",
        "whyteroutes.premium.yearly.v3",
        "whyteroutes.premiumplus.monthly.v3",
        "whyteroutes.premiumplus.yearly.v3"
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published var isPurchasing = false
    @Published var errorMessage: String?

    private var transactionListenerTask: Task<Void, Never>?
    private lazy var functions = Functions.functions()

    init() {
        transactionListenerTask = listenForTransactionUpdates()
        Task {
            await fetchProducts()
            await refreshPurchasedProducts()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Fetch StoreKit Products
    func fetchProducts() async {
        do {
            products = try await Product.products(for: Self.productIDs)
                .sorted { $0.price < $1.price }
        } catch {
            errorMessage = "Couldn't load subscription options - check your connection."
            print("❌ Error fetching StoreKit products:", error)
        }
    }

    // MARK: - Purchase Flow
    func purchase(_ product: Product) async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                await syncEntitlement(jws: verification.jwsRepresentation)
                await transaction.finish()
                purchasedProductIDs.insert(transaction.productID)

            case .userCancelled:
                break

            case .pending:
                errorMessage = "This purchase needs approval (Ask to Buy) before it completes."

            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed - \(error.localizedDescription)"
            print("❌ Purchase failed:", error)
        }
    }

    // MARK: - Restore
    func restorePurchases() async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await refreshPurchasedProducts()
            if purchasedProductIDs.isEmpty {
                errorMessage = "No previous purchase found for this Apple ID."
            }
        } catch {
            errorMessage = "Restore failed - \(error.localizedDescription)"
        }
    }

    // MARK: - Current entitlements (checked on launch, and after restore)
    func refreshPurchasedProducts() async {
        var active: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.checkVerified(result) else { continue }
            if transaction.revocationDate == nil {
                active.insert(transaction.productID)
                await syncEntitlement(jws: result.jwsRepresentation)
            }
        }
        purchasedProductIDs = active
    }

    // MARK: - Background transaction listener (renewals, cancellations,
    // purchases completed on another device) - keeps the server-side
    // tier correct even when nobody is actively looking at the paywall.
    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self, let transaction = try? Self.checkVerified(result) else { continue }
                await self.syncEntitlement(jws: result.jwsRepresentation)
                await transaction.finish()
                await MainActor.run {
                    if transaction.revocationDate == nil {
                        self.purchasedProductIDs.insert(transaction.productID)
                    } else {
                        self.purchasedProductIDs.remove(transaction.productID)
                    }
                }
            }
        }
    }

    // MARK: - Server-side entitlement sync
    private func syncEntitlement(jws: String) async {
        do {
            _ = try await functions.httpsCallable("syncSubscriptionEntitlement").call(["signedTransaction": jws])
        } catch {
            print("❌ Failed to sync entitlement to server:", error)
            errorMessage = "Purchase went through, but activating it failed - it should resolve automatically shortly, or contact support."
        }
    }

    private nonisolated static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw PurchaseError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    enum PurchaseError: LocalizedError {
        case failedVerification
        var errorDescription: String? { "Apple couldn't verify this purchase." }
    }
}
