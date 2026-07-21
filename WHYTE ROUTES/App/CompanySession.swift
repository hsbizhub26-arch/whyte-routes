import Foundation
import Combine

/// Which company (tenant) the signed-in user belongs to. Set once by
/// AuthSession after sign-in; every repository reads currentCompanyId
/// from here to scope its Firestore queries to companies/{id}/....
///
/// Deliberately not @MainActor: repositories are plain, non-isolated
/// classes that read currentCompanyId synchronously from completion-
/// handler-based methods. Writes only ever happen from AuthSession's
/// already-MainActor-isolated auth-state callback.
final class CompanySession: ObservableObject {
    static let shared = CompanySession()
    private init() {}

    @Published var currentCompanyId: String?
    @Published var currentCompany: Company?

    func clear() {
        currentCompanyId = nil
        currentCompany = nil
    }
}
