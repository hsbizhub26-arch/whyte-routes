import SwiftUI
import MapKit

struct LiveFleetMapView: View {

    @StateObject private var driverVM = DriverViewModel()

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
        span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
    )

    var body: some View {
        Map(coordinateRegion: $region,
            annotationItems: driverVM.drivers.filter { $0.coordinate != nil }) { driver in

            MapAnnotation(coordinate: driver.coordinate!) {
                VStack {
                    Circle()
                        .fill(WRTheme.gold)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { driverVM.loadDrivers() }
    }
}
