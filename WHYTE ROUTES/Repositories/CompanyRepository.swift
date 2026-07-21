import Foundation
import FirebaseFirestore

/// Generic company (tenant) CRUD - reusable for any company, never
/// references a specific business by name.
final class CompanyRepository {

    private let db = Firestore.firestore()

    func fetch(companyId: String) async -> Company? {
        guard let snapshot = try? await db.collection("companies").document(companyId).getDocument(),
              let data = snapshot.data() else {
            return nil
        }
        return Company(from: data, id: snapshot.documentID)
    }

    /// Finds the company a given user owns, if any. Used for the
    /// platform-owner bootstrap path (see AuthSession) so a newly
    /// created company can be found on subsequent logins without
    /// needing its ID stored anywhere else yet.
    func fetchOwnedCompany(ownerUID: String) async -> Company? {
        guard let snapshot = try? await db.collection("companies")
            .whereField("ownerUID", isEqualTo: ownerUID)
            .limit(to: 1)
            .getDocuments(),
            let doc = snapshot.documents.first
        else {
            return nil
        }
        return Company(from: doc.data(), id: doc.documentID)
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
