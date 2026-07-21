import Foundation
import FirebaseFirestore

final class CustomerRepository {

    private let db = Firestore.firestore()

    // MARK: - Fetch Customers Once
    func fetchCustomers(_ completion: @escaping (Result<[Customer], Error>) -> Void) {
        db.collection("customers")
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
        db.collection("customers")
            .document(customer.id)
            .setData(customer.toDict()) { error in
                completion?(error == nil)
            }
    }
}
