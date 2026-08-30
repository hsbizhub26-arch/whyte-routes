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

    // MARK: - Update Customer (editing an existing record, e.g. adding
    // driver notes after the fact - same full-document write as
    // create, just against an existing id instead of a new one)
    func updateCustomer(_ customer: Customer, completion: ((Bool) -> Void)? = nil) {
        guard let customersRef else { completion?(false); return }

        customersRef
            .document(customer.id)
            .setData(customer.toDict()) { error in
                completion?(error == nil)
            }
    }

    // MARK: - Delete Customer
    // There was no way to remove a customer from inside the app at all
    // - not a broken swipe, simply never built. Which meant a customer
    // entered by mistake, or one who has left, stayed in the list and
    // kept counting against the plan's customer limit forever.
    //
    // This removes the customer RECORD only. Stops already built from
    // that customer keep their own cached copy of the name and address,
    // deliberately: deleting a customer must not silently blank out a
    // route the crew is part-way through driving. What it does stop is
    // any further contact - the send paths treat a stop whose named
    // customer no longer exists as having no consent, rather than
    // falling back to the phone number frozen on the stop.
    func deleteCustomer(id: String, completion: ((Bool) -> Void)? = nil) {
        guard let customersRef else { completion?(false); return }

        customersRef.document(id).delete { error in
            if let error {
                print("❌ Failed to delete customer \(id): \(error.localizedDescription)")
            }
            completion?(error == nil)
        }
    }
}
