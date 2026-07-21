import Foundation
import Combine

class AdminSession: ObservableObject {
    static let shared = AdminSession()
    private init() {}

    @Published var isAdminLoggedIn = false
    @Published var adminName: String = "Admin"
}
