import Foundation
import FirebaseFirestore

/// Generic company (tenant) CRUD - reusable for any company, never
/// references a specific business by name.
final class CompanyRepository {

    private let db = Firestore.firestore()

    func fetch(companyId: String) async -> Company? {
        do {
            let snapshot = try await db.collection("companies").document(companyId).getDocument()
            guard let data = snapshot.data() else { return nil }
            return Company(from: data, id: snapshot.documentID)
        } catch {
            print("⚠️ CompanyRepository.fetch(\(companyId)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Finds the company a given user owns, if any. Used for the
    /// platform-owner bootstrap path (see AuthSession) so a newly
    /// created company can be found on subsequent logins without
    /// needing its ID stored anywhere else yet.
    func fetchOwnedCompany(ownerUID: String) async -> Company? {
        do {
            let snapshot = try await db.collection("companies")
                .whereField("ownerUID", isEqualTo: ownerUID)
                .limit(to: 1)
                .getDocuments()

            guard let doc = snapshot.documents.first else {
                print("🔍 CompanyRepository.fetchOwnedCompany(\(ownerUID)): query succeeded, 0 matching documents")
                return nil
            }
            return Company(from: doc.data(), id: doc.documentID)
        } catch {
            print("⚠️ CompanyRepository.fetchOwnedCompany(\(ownerUID)) query FAILED (likely Firestore rules, not \"not found\"): \(error.localizedDescription)")
            return nil
        }
    }

    /// Targeted update (not a full setData) - only ever touches this
    /// one field, which is what the Firestore rule for this specific
    /// case checks (a company owner may update navigationSettings on
    /// their own company; nothing else is opened up by this path -
    /// name/subscriptionTier/billing stay platform-admin-only).
    func updateNavigationSettings(companyId: String, settings: NavigationSettings) async -> Bool {
        do {
            try await db.collection("companies").document(companyId)
                .updateData(["navigationSettings": settings.toDict()])
            return true
        } catch {
            print("⚠️ CompanyRepository.updateNavigationSettings(\(companyId)) failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func create(_ company: Company) async -> Company? {
        let docRef = db.collection("companies").document()
        do {
            try await docRef.setData(company.toDict())
            var created = company
            created.id = docRef.documentID
            return created
        } catch {
            print("⚠️ Failed to create company \(company.name): \(error.localizedDescription)")
            return nil
        }
    }
}
