import SwiftUI
import MapKit

struct LiveFleetMapView: View {
    
    @StateObject private var driverService = DriverService.shared
    
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
        span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
    )
    
    var body: some View {
        Map(coordinateRegion: $region,
            annotationItems: driverService.drivers.compactMap { $0.lastKnownLocation }) { loc in
            
            MapAnnotation(coordinate: CLLocationCoordinate2D(latitude: loc.lat, longitude: loc.lng)) {
                VStack {
                    Circle()
                        .fill(WRTheme.gold)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
            }
        }
        .ignoresSafeArea()
    }
}
