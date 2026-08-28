import SwiftUI
import MapKit
import Combine

@MainActor
final class DriverMapViewModel: ObservableObject {

    @Published var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
            span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
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
                self?.cameraPosition = .region(
                    MKCoordinateRegion(center: coordinate, span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04))
                )
            }
            .store(in: &cancellables)
    }

    func centerOnDriver() {
        if let coord = driverCoordinate {
            cameraPosition = .region(
                MKCoordinateRegion(center: coord, span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04))
            )
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

            if let trackingError = LocationService.shared.trackingError {
                gpsBanner(text: trackingError, color: .red)
            } else if vm.driverCoordinate == nil {
                gpsBanner(
                    text: DriverSession.shared.activeShift == nil
                        ? "Start your shift to begin live tracking."
                        : "Waiting for GPS…",
                    color: Color("WRThemeGold")
                )
            }
        }
    }

    // Shown either while waiting for the first GPS fix (normal, gold)
    // or when tracking has genuinely broken - permission revoked, a
    // real CLError - partway through a shift (a real problem, red, so
    // it reads as different from "just starting up").
    private func gpsBanner(text: String, color: Color) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.footnote.bold())
                .foregroundColor(.black)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(color)
                .clipShape(Capsule())
                .shadow(radius: 6)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
        }
    }

    // Route order, not whatever order Firestore happened to return -
    // this is what the pin numbers and the polyline are both drawn
    // from, so "stop 4" on the map is the same stop 4 the driver sees
    // in the Route list.
    private var orderedStops: [Stop] {
        vm.stops.sorted { $0.order < $1.order }
    }

    // MARK: - MAP LAYER
    // Numbered pins + a connecting line - the same inRoute-style
    // "see your whole run at a glance" treatment LiveFleetMapView
    // already gives the owner's fleet view, now on the driver's own
    // map too instead of unlabeled dots.
    private var mapLayer: some View {
        Map(position: $vm.cameraPosition) {
            UserAnnotation()

            let routeCoordinates = ([vm.driverCoordinate] + orderedStops.compactMap { $0.coordinate }).compactMap { $0 }
            if routeCoordinates.count > 1 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(Color("WRThemeGold"), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }

            ForEach(Array(orderedStops.enumerated()), id: \.element.id) { index, stop in
                if let coordinate = stop.coordinate {
                    Annotation("", coordinate: coordinate) {
                        VStack(spacing: 2) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .frame(width: 26, height: 26)
                                .background(stop.isCompleted ? Color.green : Color("WRThemeGold"))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .opacity(stop.isCompleted ? 0.55 : 1)
                                .shadow(color: .black.opacity(0.35), radius: 4)

                            Text(stop.customerName ?? "")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Capsule())
                        }
                        .onTapGesture {
                            vm.selectedStop = stop
                        }
                    }
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
            if vm.selectedStop != nil {
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
