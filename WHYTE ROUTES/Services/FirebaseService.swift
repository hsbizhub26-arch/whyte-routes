import Foundation
import FirebaseCore

/// Safely initializes Firebase if it has not already been configured.
/// Prevents duplicate configuration crashes.
final class FirebaseService {

    static let shared = FirebaseService()
    private init() {}

    func configureIfNeeded() {
        // Avoid duplicate configuration
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
            print("[FirebaseService] Firebase configured successfully.")
        } else {
            print("[FirebaseService] Firebase already configured. Skipping.")
        }
    }
}
