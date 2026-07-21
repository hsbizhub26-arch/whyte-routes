import SwiftUI
import MapKit

struct DriverLiveMapView: View {

    @StateObject private var vm = LiveMapViewModel.shared
    @ObservedObject private var session = DriverSession.shared

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
    )

    var body: some View {
        ZStack {

            // MARK: - MAP
            Map(
                coordinateRegion: $region,
                showsUserLocation: true,
                annotationItems: vm.stopAnnotations
            ) { stop in
                MapAnnotation(coordinate: stop.coordinate) {
                    ZStack {
                        Circle()
                            .fill(stop.isCompleted ? Color.green : Color("WRThemeGold"))
                            .frame(width: 22, height: 22)

                        Circle()
                            .stroke(Color.black, lineWidth: 2)
                            .frame(width: 26, height: 26)
                    }
                }
            }
            .ignoresSafeArea()


            // MARK: - TOP INFO OVERLAY (Black + Gold)
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {

                        if let driver = session.driver {
                            Text(driver.name)
                                .font(.headline.weight(.medium))
                                .foregroundColor(Color("WRThemeGold"))

                            if let route = session.assignedRoute {
                                Text("Route: \(route.name)")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }

                    Spacer()
                }
                .padding(14)
                .background(
                    Color("WRBlack")
                        .opacity(0.92)
                        .blur(radius: 2)
                )
                .cornerRadius(14)
                .shadow(color: Color("WRThemeGold").opacity(0.4), radius: 6, x: 0, y: 3)
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer()
            }


            // MARK: - BOTTOM NEXT STOP BUTTON
            VStack {
                Spacer()

                if let next = vm.nextStop {
                    Button {
                        vm.goToNextStop()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next Stop")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.8))

                                Text(next.customerName)
                                    .font(.headline.weight(.bold))
                                    .foregroundColor(Color("WRThemeGold"))
                            }

                            Spacer()

                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title2)
                                .foregroundColor(Color("WRThemeGold"))
                        }
                        .padding()
                        .background(Color("WRBlack").opacity(0.9))
                        .cornerRadius(16)
                        .shadow(color: Color("WRThemeGold").opacity(0.35),
                                radius: 6, x: 0, y: 3)
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            vm.startListening()
            centerOnDriver()
        }
    }

    // MARK: - Center map on driver
    private func centerOnDriver() {
        guard let coord = vm.driverCoordinate else { return }
        region.center = coord
    }
}
