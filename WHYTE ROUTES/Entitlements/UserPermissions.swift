struct UserPermissions {
    static var isPremium: Bool {
        AppEntitlements.shared.premiumUnlocked
    }

    static var isPremiumPlus: Bool {
        AppEntitlements.shared.premiumPlusUnlocked
    }

    static var isFreeUser: Bool {
        !isPremium && !isPremiumPlus
    }
}
