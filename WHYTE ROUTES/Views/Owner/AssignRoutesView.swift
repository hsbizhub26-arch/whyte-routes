import SwiftUI
import FirebaseFirestore

struct AssignRoutesDriver: Identifiable, Codable {
    let id: String
    var name: String
    var vehicle: String
    var activeRoute: String?
}

struct AssignRouteView: View {

    let routeId: String
    @State private var drivers: [AssignRoutesDriver] = []

    var body: some View {
        List(drivers) { driver in
            Button {
                assignRoute(to: driver)
            } label: {
                VStack(alignment: .leading) {
                    Text(driver.name)
                        .foregroundColor(.primary)
                    Text(driver.vehicle)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .onAppear(perform: loadDrivers)
        .navigationTitle("Assign Driver")
    }

    func loadDrivers() {
        Firestore.firestore()
            .collection("drivers")
            .getDocuments { snap, _ in
                guard let docs = snap?.documents else { return }
                drivers = docs.compactMap { doc in
                    let data = doc.data()
                    guard let name = data["name"] as? String,
                          let vehicle = data["vehicle"] as? String else {
                        return nil
                    }
                    let activeRoute = data["activeRoute"] as? String
                    return AssignRoutesDriver(id: doc.documentID, name: name, vehicle: vehicle, activeRoute: activeRoute)
                }
            }
    }

    func assignRoute(to driver: AssignRoutesDriver) {
        let db = Firestore.firestore()

        db.collection("routes").document(routeId)
            .updateData(["driverId": driver.id])

        db.collection("drivers").document(driver.id)
            .updateData(["activeRoute": routeId])
    }
}

