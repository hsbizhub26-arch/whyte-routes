import SwiftUI
import MapKit

struct NativeMapView: View {
    
    @Binding var region: MKCoordinateRegion
    var driverLocation: CLLocationCoordinate2D?
    var routePolyline: MKPolyline?
    
    var body: some View {
        Map(coordinateRegion: $region,
            annotationItems: driverLocation.map({ [LocationAnnotation(coordinate: $0)] }) ?? []) { annotation in
            MapAnnotation(coordinate: annotation.coordinate) {
                Circle()
                    .fill(WRTheme.gold)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
        }
        .overlay(routeOverlay)
        .ignoresSafeArea()
    }
    
    var routeOverlay: some View {
        RouteDrawer(polyline: routePolyline)
    }
}

struct LocationAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}
