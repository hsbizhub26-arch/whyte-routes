import Foundation
import Combine
import FirebaseFirestore

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

    private var companyListener: ListenerRegistration?

    /// Keeps currentCompany LIVE for as long as the user is signed in.
    ///
    /// This used to be a single getDocument at sign-in, which made the
    /// subscription tier a snapshot of whatever was true the moment
    /// they logged in. So a customer bought Premium Plus, the Cloud
    /// Function wrote the new tier, and their app went on believing
    /// they were on Starter - paywall still showing prices, gated
    /// screens still blocked - until they happened to fully relaunch.
    /// Nothing in the app told them to. To a reviewer testing the IAP
    /// that reads as "purchased content did not unlock", which is a
    /// Guideline 2.1 rejection; to a paying customer it reads as
    /// having been charged for nothing.
    func startListening(companyId: String) {
        guard currentCompanyId != companyId || companyListener == nil else { return }
        companyListener?.remove()
        currentCompanyId = companyId

        companyListener = Firestore.firestore()
            .collection("companies")
            .document(companyId)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    // Keep the last known company rather than blanking
                    // it - losing signal must not silently downgrade
                    // someone to Starter mid-shift.
                    print("⚠️ CompanySession listener error: \(error.localizedDescription)")
                    return
                }
                guard let snapshot, let data = snapshot.data() else { return }
                self.currentCompany = Company(from: data, id: snapshot.documentID)
            }
    }

    func clear() {
        companyListener?.remove()
        companyListener = nil
        currentCompanyId = nil
        currentCompany = nil
    }
}
