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

    // Observes whatever LocationService is already publishing - actual
    // tracking start/stop is tied to the shift lifecycle (see
    // DriverSession.startShift/endShift), not to this screen appearing.
    func startLocationUpdates() {
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
                .ignoresSafeArea()

            // topButtons/stopSheet/waitingForGPSBanner deliberately do
            // NOT ignore the safe area - the map filling the whole
            // screen is correct, but UI overlays need the safe-area
            // padding to stay clear of the tab bar. Applying
            // ignoresSafeArea() to this entire ZStack (old code) made
            // the banner lose that padding and render on top of the
            // tab bar instead of above it.
            topButtons
            stopSheet

            if vm.driverCoordinate == nil {
                waitingForGPSBanner
            }
        }
    }

    // Shown until the first GPS fix arrives - true before a shift has
    // started (tracking is tied to the shift lifecycle, not this
    // screen) and briefly after, until CoreLocation reports a location.
    private var waitingForGPSBanner: some View {
        VStack {
            Spacer()
            Text(DriverSession.shared.activeShift == nil
                 ? "Start your shift to begin live tracking."
                 : "Waiting for GPS…")
                .font(.footnote.bold())
                .foregroundColor(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color("WRThemeGold"))
                .clipShape(Capsule())
                .shadow(radius: 6)
                .padding(.bottom, 40)
        }
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
