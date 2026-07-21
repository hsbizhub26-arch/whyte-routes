import SwiftUI
import MapKit
import FirebaseFirestore

struct ManagerLiveFleetMapView: View {
    
    @State private var drivers: [Driver] = []
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    
    var body: some View {
        ZStack(alignment: .top) {
            
            Map(coordinateRegion: $region, annotationItems: drivers) { driver in
                MapMarker(
                    coordinate: CLLocationCoordinate2D(latitude: driver.lat ?? 0, longitude: driver.lng ?? 0),
                    tint: .yellow
                )
            }
            .ignoresSafeArea()
            
            VStack(alignment: .leading) {
                Text("Live Fleet Map")
                    .font(.title2.bold())
                    .foregroundColor(.yellow)
                    .padding(.top, 40)
                    .padding(.leading, 20)
                
                ForEach(drivers) { d in
                    HStack {
                        Circle().fill(Color.yellow).frame(width: 10, height: 10)
                        Text(d.name)
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(Int(d.lat ?? 0)), \(Int(d.lng ?? 0))")
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal)
                }
            }
        }
        .onAppear { listenToDrivers() }
    }
    
    func listenToDrivers() {
        Firestore.firestore()
            .collection("drivers")
            .addSnapshotListener { snap, error in
                drivers = snap?.documents.compactMap {
                    try? $0.data(as: Driver.self)
                } ?? []
            }
    }
}
