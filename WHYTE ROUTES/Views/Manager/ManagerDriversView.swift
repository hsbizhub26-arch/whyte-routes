import SwiftUI
import FirebaseFirestore

struct ManagerDriversView: View {

    @State private var drivers: [Driver] = []

    var body: some View {
        List(drivers) { driver in
            NavigationLink(destination: ManagerDriverInfoView(driver: driver)) {
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
                drivers = docs.compactMap { Driver(from: $0.data(), id: $0.documentID) }
            }
    }
}

/// A manager's read-only view of one of their drivers (as opposed to
/// DriverDetailView, which is a driver's view of their own profile).
struct ManagerDriverInfoView: View {
    let driver: Driver

    var body: some View {
        List {
            Section("Driver") {
                LabeledContent("Name", value: driver.name)
                LabeledContent("Vehicle", value: driver.vehicle)
                if let phone = driver.phone {
                    LabeledContent("Phone", value: phone)
                }
            }
            Section("Status") {
                LabeledContent("Active Route", value: driver.activeRoute ?? "None")
                if let updated = driver.lastUpdated {
                    LabeledContent("Last Updated", value: TimestampFormatter.shared.asTimeAgo(updated))
                }
            }
        }
        .navigationTitle(driver.name)
    }
}
