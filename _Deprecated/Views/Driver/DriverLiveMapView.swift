import SwiftUI
import MapKit
import CoreLocation

struct DriverLiveMapView: View {

    // MARK: - Dependencies
    @StateObject private var nextStop = DriverNextStopController.shared
    @StateObject private var locationManager: DriverLocationManager
    
    let stop: Stop
    
    // MARK: - Map Region
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
        span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    // MARK: - Init
    init(stop: Stop, driverId: String) {
        self.stop = stop
        _locationManager = StateObject(wrappedValue: DriverLocationManager(driverId: driverId))
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            VStack(spacing: 0) {

                mapSection

                actionSection
            }
        }
        .onAppear {
            locationManager.startStop(stopId: stop.id ?? "")
            updateRegionToDriver()
        }
        .onReceive(locationManager.$currentLocation) { _ in
            updateRegionToDriver()
        }
        .navigationTitle("Live Navigation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension DriverLiveMapView {

    // MARK: - MAP
    private var mapSection: some View {
        Map(
            coordinateRegion: $region,
            annotationItems: annotations
        ) { item in
            MapMarker(coordinate: item.coordinate, tint: item.color)
        }
        .frame(maxHeight: 380)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding()
    }

    // MARK: - ACTIONS
    private var actionSection: some View {
        VStack(spacing: 18) {

            Text(stop.address)
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // NAVIGATION BUTTON
            NavigationButton(coordinate: stop.coordinate)

            // ETA / DISTANCE
            if let loc = locationManager.currentLocation {
                let dist = DriverNextStopController.shared.distance(from: loc, to: stop.coordinate)
                let eta = DriverNextStopController.shared.eta(from: loc, to: stop.coordinate)

                VStack(spacing: 4) {
                    Text("Distance: \(dist)")
                        .foregroundColor(Color("WRThemeGold"))
                    Text("ETA: \(eta)")
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            // COMPLETE BUTTON
            Button {
                finishStop()
            } label: {
                Text("Mark Stop Completed")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color("WRThemeGold"))
                    .foregroundColor(.black)
                    .cornerRadius(14)
                    .shadow(color: Color("WRThemeGold").opacity(0.4), radius: 8)
            }
            .padding(.horizontal)
            .padding(.bottom, 22)
        }
    }

    // MARK: - Helpers
    
    private var annotations: [MapPinItem] {
        var items: [MapPinItem] = []

        if let driverCoord = locationManager.currentLocation {
            items.append(MapPinItem(
                coordinate: driverCoord,
                color: .yellow
            ))
        }

        items.append(MapPinItem(
            coordinate: stop.coordinate,
            color: .red
        ))

        return items
    }

    private func updateRegionToDriver() {
        guard let coord = locationManager.currentLocation else { return }
        region.center = coord
    }

    private func finishStop() {
        locationManager.finishStop()
        DriverNextStopController.shared.markCompleted(stop)
    }
}

// MARK: - Map Helper Struct
struct MapPinItem: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let color: Color
}
