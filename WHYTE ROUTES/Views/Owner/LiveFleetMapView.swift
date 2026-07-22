import SwiftUI
import MapKit

struct LiveFleetMapView: View {

    @StateObject private var driverVM = DriverViewModel()
    @ObservedObject private var access = FeatureAccessManager.shared

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
        span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
    )

    var body: some View {
        if access.canAccessLiveFleetMap() {
            map
        } else {
            UpgradeRequiredView(featureName: "Live Fleet Map", requiredTier: access.requiredTierForLiveFleetMap)
        }
    }

    private var map: some View {
        Map(coordinateRegion: $region,
            annotationItems: driverVM.drivers.filter { $0.coordinate != nil }) { driver in

            MapAnnotation(coordinate: driver.coordinate!) {
                VStack(spacing: 2) {
                    Circle()
                        .fill(driver.color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.4), radius: 4)

                    Text(driver.name)
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.7))
                        .clipShape(Capsule())
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { driverVM.loadDrivers() }
    }
}
