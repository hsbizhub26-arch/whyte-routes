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
            .setData(customer.toDict()) { [weak self] error in
                if error == nil {
                    self?.propagateToOpenStops(customer)
                }
                completion?(error == nil)
            }
    }

    // MARK: - Push a corrected customer down onto their open stops
    //
    // Stops keep their OWN copy of the customer's name, address and
    // coordinates - denormalised so a driver's stop list works without
    // a join, and so a route stays intact if a customer is later
    // deleted. Nothing ever updated that copy, which made correcting a
    // customer feel broken in the worst way: the customer record got
    // fixed, the route the driver was actually looking at did not, and
    // there was nothing on screen to explain the difference.
    //
    // It bites hardest on exactly the case that needs it. An address
    // typed by hand rather than picked from the suggestions is stored
    // with no coordinates, so navigation cannot start; the owner
    // re-enters it properly, and the driver's stop still has no map
    // location, because the fix never travelled.
    //
    // ONLY open stops, and ONLY the customer-derived fields. A
    // completed stop is a record of what happened and must not be
    // rewritten afterwards, and status, timestamps, order and driverId
    // belong to the driver - the same line drawn in
    // StopsRepository.saveRouteEdits, for the same reason.
    private func propagateToOpenStops(_ customer: Customer) {
        guard let companyId = CompanySession.shared.currentCompanyId else { return }
        let routesRef = db.collection("companies").document(companyId).collection("routes")

        routesRef.getDocuments { snapshot, error in
            guard error == nil, let routes = snapshot?.documents else { return }

            for route in routes {
                route.reference.collection("stops")
                    .whereField("customerId", isEqualTo: customer.id)
                    .getDocuments { stopSnap, stopError in
                        guard stopError == nil, let stops = stopSnap?.documents else { return }

                        for stop in stops {
                            let isCompleted = stop.data()["isCompleted"] as? Bool ?? false
                            guard !isCompleted else { continue }

                            var data: [String: Any] = [
                                "address": customer.address,
                                "customerOptedIn": customer.notificationsOptIn
                            ]
                            func put(_ key: String, _ value: Any?) {
                                data[key] = value ?? FieldValue.delete()
                            }
                            put("customerName", customer.name)
                            put("customerPhone", customer.phone)
                            put("customerEmail", customer.email)
                            put("driverNotes", customer.notes)
                            put("latitude", customer.latitude)
                            put("longitude", customer.longitude)

                            stop.reference.setData(data, merge: true)
                        }
                    }
            }
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
