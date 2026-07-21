import Foundation
import FirebaseFirestore

final class CustomerRepository {

    private let db = Firestore.firestore()

    /// Customers always live under the signed-in user's current
    /// company. nil (logged) if no company is set.
    private var customersRef: CollectionReference? {
        guard let companyId = CompanySession.shared.currentCompanyId else {
            print("⚠️ CustomerRepository: no current company set - cannot access customers")
            return nil
        }
        return db.collection("companies").document(companyId).collection("customers")
    }

    // MARK: - Fetch Customers Once
    func fetchCustomers(_ completion: @escaping (Result<[Customer], Error>) -> Void) {
        guard let customersRef else { completion(.success([])); return }

        customersRef
            .getDocuments { snapshot, error in

                if let error = error {
                    completion(.failure(error))
                    return
                }

                let customers: [Customer] = snapshot?.documents.compactMap { doc in
                    Customer(from: doc.data(), id: doc.documentID)
                } ?? []

                completion(.success(customers))
            }
    }

    // MARK: - Create Customer
    func createCustomer(_ customer: Customer, completion: ((Bool) -> Void)? = nil) {
        guard let customersRef else { completion?(false); return }

        customersRef
            .document(customer.id)
            .setData(customer.toDict()) { error in
                completion?(error == nil)
            }
    }
}
