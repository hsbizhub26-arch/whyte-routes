import SwiftUI
import MapKit
import FirebaseFirestore

struct FleetMapView: View {

    @State private var drivers: [DriverLocation] = []

    var body: some View {
        Map(
            coordinateRegion: .constant(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
                    span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
                )
            ),
            annotationItems: drivers
        ) { driver in
            MapMarker(coordinate: driver.coordinate, tint: .yellow)
        }
        .onAppear(perform: listenDrivers)
        .navigationTitle("Live Map")
    }

    func listenDrivers() {
        Firestore.firestore().collection("drivers")
            .addSnapshotListener { snap, _ in
                guard let docs = snap?.documents else { return }

                drivers = docs.compactMap { doc in
                    let data = doc.data()
                    guard let lat = data["lat"] as? Double,
                          let lng = data["lng"] as? Double else { return nil }

                    return DriverLocation(
                        id: doc.documentID,
                        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    )
                }
            }
    }
}

struct DriverLocation: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
}
