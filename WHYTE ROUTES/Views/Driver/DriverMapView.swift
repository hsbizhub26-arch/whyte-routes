import SwiftUI
import MapKit
import Combine

@MainActor
final class DriverMapViewModel: ObservableObject {

    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
        span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )

    @Published var driverCoordinate: CLLocationCoordinate2D?
    @Published var stops: [Stop] = []
    @Published var selectedStop: Stop?

    private let session = DriverSession.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadStops()
        startLocationUpdates()
    }

    func loadStops() {
        stops = session.activeStops
    }

    // Live GPS updates via LocationService
    func startLocationUpdates() {
        guard let driverId = session.driver?.id else { return }
        LocationService.shared.startTracking(driverId: driverId, stopLat: nil, stopLng: nil)

        LocationService.shared.$currentLocation
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coordinate in
                self?.driverCoordinate = coordinate
                self?.region.center = coordinate
            }
            .store(in: &cancellables)
    }

    func centerOnDriver() {
        if let coord = driverCoordinate {
            region.center = coord
        }
    }
}

struct DriverMapView: View {

    @StateObject private var vm = DriverMapViewModel()

    var body: some View {
        ZStack {
            mapLayer
            topButtons
            stopSheet
        }
        .ignoresSafeArea()
    }

    // MARK: - MAP LAYER
    private var mapLayer: some View {
        Map(coordinateRegion: $vm.region,
            showsUserLocation: true,
            annotationItems: vm.stops.filter { $0.coordinate != nil }
        ) { stop in
            MapAnnotation(coordinate: stop.coordinate!) {
                VStack(spacing: 2) {
                    Circle()
                        .fill(stop.isCompleted ? .green : Color("WRThemeGold"))
                        .frame(width: 18, height: 18)
                        .shadow(color: Color("WRThemeGold").opacity(0.4), radius: 6)

                    Text(stop.customerName ?? "")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .onTapGesture {
                    vm.selectedStop = stop
                }
            }
        }
    }

    // MARK: - BUTTONS (top-right)
    private var topButtons: some View {
        VStack {
            HStack {
                Spacer()

                Button {
                    vm.centerOnDriver()
                } label: {
                    Image(systemName: "location.fill")
                        .foregroundColor(.black)
                        .padding(10)
                        .background(Color("WRThemeGold"))
                        .clipShape(Circle())
                        .shadow(radius: 6)
                }
                .padding()
            }
            Spacer()
        }
    }

    // MARK: - STOP DETAIL SHEET
    private var stopSheet: some View {
        Group {
            if let stop = vm.selectedStop {
                EmptyView()
                    .sheet(item: Binding<Stop?>(
                        get: { vm.selectedStop },
                        set: { vm.selectedStop = $0 }
                    )) { s in
                        DriverStopView(stop: s)
                    }
            }
        }
    }
}
