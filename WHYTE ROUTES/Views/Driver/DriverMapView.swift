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

    /// The region the map is actually showing, kept current by
    /// onMapCameraChange. Needed because cameraPosition is usually
    /// .userLocation(...) rather than a region, so there is nothing to
    /// read a span off when the driver asks to zoom - MapKit knows
    /// where the camera is, this is how we find out.
    var visibleRegion: MKCoordinateRegion?

    /// Zoom by a factor around whatever is on screen right now.
    /// Switching to an explicit .region also stops the camera following
    /// the driver, which is the right behaviour: someone who just
    /// pinched out to see the rest of their route does not want the map
    /// snapping back to their own dot on the next GPS fix. The locate
    /// button puts them back.
    func zoom(by factor: Double) {
        guard let region = visibleRegion else { return }
        // Clamped so repeated taps can't invert the span or zoom out
        // past the whole world, both of which MapKit renders as a
        // blank grey rectangle.
        let latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.0008), 120)
        let longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.0008), 120)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: region.center,
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            )
        )
    }
}

struct DriverMapView: View {

    @StateObject private var vm = DriverMapViewModel()

    /// Height (from the bottom safe area) of any card the parent lays
    /// over this map - e.g. DriverDashboardView's status card. The
    /// control column lifts above it so the locate/zoom buttons are
    /// never swallowed by the drawer. 0 when nothing overlays the map.
    var bottomInset: CGFloat = 0

    var body: some View {
        ZStack {
            mapLayer
                .ignoresSafeArea()

            // mapControlColumn/stopSheet/waitingForGPSBanner deliberately
            // do NOT ignore the safe area - the map filling the whole
            // screen is correct, but UI overlays need the safe-area
            // padding to stay clear of the tab bar. Applying
            // ignoresSafeArea() to this entire ZStack (old code) made
            // the banner lose that padding and render on top of the
            // tab bar instead of above it.
            mapControlColumn
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
        // TOP-anchored, not bottom.
        //
        // The banner used to sit at the bottom of the map with 40pt of
        // padding, which was fine when the map was the whole screen.
        // The driver dashboard now lays a status card over the bottom
        // of that same map, so the two were drawing on top of each
        // other - "Start your shift to begin live tracking" printed
        // straight through the next stop's name and address.
        //
        // The top is genuinely free: the only thing up here is the
        // locate button in the corner, which this clears with a 56pt
        // offset. safeAreaPadding keeps it out of the status bar, since
        // the map itself is deliberately full-bleed.
        VStack {
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
                .padding(.top, 56)
            Spacer()
        }
        .safeAreaPadding(.top)
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
        // Feeds DriverMapViewModel.visibleRegion so the zoom buttons
        // have a span to scale. cameraPosition is normally
        // .userLocation(...), which carries no region of its own -
        // without this the buttons would have nothing to work from.
        .onMapCameraChange { context in
            vm.visibleRegion = context.region
        }
    }

    // MARK: - MAP CONTROLS (right edge)
    // A control column on the right edge rather than a single button in
    // the corner.
    //
    // The corner was wrong twice over: it sat level with the Dynamic
    // Island, which swallows touches there, and it put the one control
    // a driver uses while moving at the furthest point from their
    // thumb. Vertically centred on the right is where a hand already
    // is, and it leaves the top of the map clear for the GPS banner.
    //
    // Zoom buttons sit with it because pinching is a two-handed gesture
    // and this is used from a truck. They are not a replacement for
    // pinch - that still works - they are the one-handed version.
    private var mapControls: some View {
        VStack(spacing: 0) {
            Button {
                vm.zoom(by: 0.5)
            } label: {
                controlGlyph("plus")
            }

            Divider()
                .frame(width: 30)
                .overlay(Color.black.opacity(0.15))

            Button {
                vm.zoom(by: 2.0)
            } label: {
                controlGlyph("minus")
            }
        }
        .background(Color("WRThemeGold"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(radius: 6)
    }

    private func controlGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.black)
            .frame(width: 46, height: 44)
            .contentShape(Rectangle())
    }

    // How far up from the bottom safe area the control column sits.
    // These controls respect the safe area (they are NOT part of the
    // full-bleed map layer), so a small gap clears the tab bar; lift
    // further to clear the status card the parent overlays (bottomInset).
    private var controlColumnBottomPadding: CGFloat {
        bottomInset > 0 ? bottomInset + 12 : 16
    }

    private var mapControlColumn: some View {
        // Right edge, low where a thumb rests. Anchored to the bottom
        // (not vertically centred) with clearance below, so the status
        // card or route banner rising over the map can never swallow the
        // locate button. See mapControls for why the top corner was wrong.
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    mapControls

                    Button {
                        vm.centerOnDriver()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 46, height: 46)
                            .background(Color("WRThemeGold"))
                            .clipShape(Circle())
                            .shadow(radius: 6)
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .padding(.bottom, controlColumnBottomPadding)
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
