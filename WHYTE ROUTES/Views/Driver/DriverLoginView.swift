import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct DriverLoginView: View {

    @State private var phone = ""
    @State private var loading = false
    @State private var errorMessage: String?

    @ObservedObject var session = DriverSession.shared

    private let db = Firestore.firestore()

    var body: some View {
        VStack(spacing: 24) {

            Text("Driver Login")
                .font(.largeTitle.bold())
                .foregroundColor(Color("WRThemeGold"))
                .padding(.top, 40)

            TextField("Enter Phone Number", text: $phone)
                .keyboardType(.phonePad)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

            if let err = errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .font(.callout)
            }

            Button(action: loginDriver) {
                if loading {
                    ProgressView().tint(.white)
                } else {
                    Text("Login")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.black)
            .cornerRadius(14)
            .padding(.horizontal)
            .disabled(loading || phone.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer()
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - LOGIN LOGIC
    private func loginDriver() {
        let cleanPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanPhone.isEmpty else {
            errorMessage = "Phone number required"
            return
        }

        loading = true
        errorMessage = nil

        db.collection("drivers")
            .whereField("phone", isEqualTo: cleanPhone)
            .getDocuments { snapshot, error in

                DispatchQueue.main.async {
                    loading = false
                }

                if let error = error {
                    errorMessage = "Login failed: \(error.localizedDescription)"
                    return
                }

                guard let doc = snapshot?.documents.first else {
                    errorMessage = "No driver found with that phone number"
                    return
                }

                // Decode driver
                guard let driver = Driver(from: doc.data(), id: doc.documentID) else {
                    errorMessage = "Driver record corrupted"
                    return
                }

                // Assign session driver
                Task { @MainActor in
                    session.driver = driver

                    // Set driverId for tracking manager
                    DriverLocationManager.shared.setDriverId(driver.id)

                    // If driver has an assigned route, pull stops
                    fetchRouteAndStops(for: driver)
                }
            }
    }

    // MARK: - LOAD DRIVER ROUTE & STOPS INTO SESSION
    private func fetchRouteAndStops(for driver: Driver) {

        guard let routeId = driver.activeRoute else {
            session.assignedRoute = nil
            session.activeStops = []
            return
        }

        // Fetch the assigned route
        db.collection("routes").document(routeId).getDocument { snap, _ in
            guard let data = snap?.data(),
                  let route = Route(from: data, id: routeId)
            else {
                Task { @MainActor in
                    session.assignedRoute = nil
                    session.activeStops = []
                }
                return
            }

            // Fetch stops subcollection
            db.collection("routes")
                .document(routeId)
                .collection("stops")
                .order(by: "order")
                .getDocuments { stopsSnap, _ in

                    let stops = stopsSnap?.documents.compactMap {
                        try? $0.data(as: Stop.self)
                    } ?? []

                    Task { @MainActor in
                        session.assignedRoute = route
                        session.activeStops = stops
                    }
                }
        }
    }
}

