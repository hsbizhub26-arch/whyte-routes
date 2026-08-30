import SwiftUI
import MapKit
import Combine

@MainActor
final class DriverMapViewModel: ObservableObject {

    // Follows the driver natively via MapKit rather than us writing a
    // new region on every fix - see startLocationUpdates for why that
    // mattered. The region is only a fallback for before the first fix
    // arrives.
    @Published var cameraPosition: MapCameraPosition = .userLocation(
        fallback: .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
                span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04)
            )
        )
    )

    @Published var driverCoordinate: CLLocationCoordinate2D?
    @Published var stops: [Stop] = []
    @Published var selectedStop: Stop?

    private let session = DriverSession.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        observeStops()
        startLocationUpdates()
    }

    /// Keeps the pins LIVE.
    ///
    /// This used to be a one-shot `loadStops()` called from init, so
    /// `stops` froze at whatever activeStops happened to hold the
    /// instant the map first appeared. A route that finished loading a
    /// moment later never drew any pins at all, and a stop completed
    /// mid-shift never turned green - the map just quietly stopped
    /// being true. Sorting once here rather than in `body` also keeps
    /// the numbering stable without re-sorting on every render pass.
    private func observeStops() {
        session.$activeStops
            .map { $0.sorted { $0.order < $1.order } }
            .receive(on: DispatchQueue.main)
            .assign(to: \.stops, on: self)
            .store(in: &cancellables)
    }

    // Observes whatever LocationService is already publishing - actual
    // tracking start/stop is tied to the shift lifecycle (see
    // DriverSession.startShift/endShift), not to this screen appearing.
    //
    // NOTE what this deliberately no longer does: write cameraPosition.
    // It used to slam the camera back to a fresh region centred on the
    // driver on every single fix - and with distanceFilter at 20m that
    // is every 20 metres of driving. The driver could not pan or zoom
    // the map at all; it snapped back under their finger, which is a
    // large part of why the screen felt broken. MapKit follows the user
    // on its own via .userLocation above, and stops following the
    // moment they pan, which is the behaviour anyone expects.
    func startLocationUpdates() {
        LocationService.shared.$currentLocation
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coordinate in
                self?.driverCoordinate = coordinate
            }
            .store(in: &cancellables)
    }

    func centerOnDriver() {
        cameraPosition = .userLocation(fallback: .automatic)
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
    // Sorted once as it arrives (see DriverMapViewModel.observeStops)
    // rather than re-sorting on every render pass.
    private var orderedStops: [Stop] { vm.stops }

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
        // The MAP is deliberately full-bleed (ignoresSafeArea(.top) at
        // the call site) so it fills the screen behind the status bar.
        // These controls inherited that and ended up UNDER the clock
        // and the Dynamic Island - visible but unreachable, because the
        // island swallows the touch. safeAreaPadding puts the buttons
        // back inside the readable area without un-bleeding the map.
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
        .safeAreaPadding(.top)
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
