import SwiftUI
import FirebaseFirestore

struct ManagerDriversView: View {

    @State private var drivers: [Driver] = []

    var body: some View {
        List(drivers) { driver in
            NavigationLink(destination: DriverDetailView(driver: driver)) {
                VStack(alignment: .leading) {
                    Text(driver.name)
                        .font(.headline)
                    Text(driver.vehicle)
                        .foregroundColor(.gray)
                }
            }
        }
        .onAppear(perform: loadDrivers)
        .navigationTitle("Drivers")
    }

    func loadDrivers() {
        Firestore.firestore()
            .collection("drivers")
            .whereField("fleetId", isEqualTo: "FLEET123")
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                drivers = docs.compactMap { try? $0.data(as: Driver.self) }
            }
    }
}
