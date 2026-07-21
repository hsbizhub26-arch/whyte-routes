//
//  PurchaseManager.swift
//  WHYTE ROUTES
//

import Foundation
import StoreKit
import Combine

@MainActor
class PurchaseManager: ObservableObject {
    
    @Published var products: [Product] = []
    @Published var purchasedProducts: [Product] = []

    // MARK: - Product IDs (MUST MATCH App Store Connect)
    let productIDs: Set<String> = [
        "whyteroutes.premium.monthly.v2",
        "whyteroutes.premium.yearly.v2",
        "whyteroutes.premiumplus.monthly.v2",
        "whyteroutes.premiumplus.yearly.v2"
    ]
    
    init() {
        Task {
            await fetchProducts()
            await updatePurchasedProducts()
        }
    }
    
    // MARK: - Fetch StoreKit Products
    func fetchProducts() async {
        do {
            self.products = try await Product.products(for: productIDs)
        } catch {
            print("❌ Error fetching StoreKit products:", error)
        }
    }

    // MARK: - Purchase Flow
    func purchase(_ product: Product) {
        Task {
            do {
                let result = try await product.purchase()
                
                switch result {
                case .success(let verification):
                    if case .verified(let transaction) = verification {
                        await handleVerifiedPurchase(transaction)
                        await transaction.finish()
                    }
                default:
