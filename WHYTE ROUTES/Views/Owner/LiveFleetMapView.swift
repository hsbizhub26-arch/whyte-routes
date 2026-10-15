import SwiftUI
import MapKit
import CoreLocation

// Nothing on the owner side ever asked iOS for location permission -
// UserAnnotation() and MapUserLocationButton() both need
// CLLocationManager authorization to have actually been granted, and
// with no request ever made the button had nothing to center on and
// silently did nothing. Drivers get this via RealtimeLocationManager
// (needed continuously, for GPS tracking); an owner just glancing at
// their own position on the fleet map needs a one-time ask, not a
// running location session, so this stays a tiny standalone requester
// rather than pulling in that whole class.
@MainActor
private final class OwnerLocationAuthorizer: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    func requestIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }
}

// The live dispatch map - every driver's live GPS position, plus each
// driver's active route drawn as a numbered, color-matched path (the
// inRoute-style numbered-pin-and-line look, but per-driver colored so
// multiple simultaneous routes stay distinguishable on one map instead
// of only ever showing one route at a time). The driver legend at the
// top is the "clean way to see each driver's route" - tap a driver to
// focus their route alone, tap again (or "All") to see the whole fleet.
struct LiveFleetMapView: View {

    // Passed in by the caller (OwnerDashboardView, which is now the
    // only place this is shown) rather than owned here, so the map and
    // the stat widgets around it share one live driver listener
    // instead of running two independent ones for the same data.
    @ObservedObject var driverVM: DriverViewModel

    /// Height (measured up from the physical bottom) of any bottom sheet
    /// the caller lays over this map - e.g. OwnerDashboardView's
    /// "Dashboard" panel when it's open. The map control column is
    /// lifted above it so the locate/zoom buttons are never hidden
    /// behind the drawer. 0 when nothing is overlaid.
    var bottomInset: CGFloat = 0
    /// Width of any panel the caller lays down the LEFT edge - the iPad
    /// owner dashboard's side panel. The selected-driver card is pushed
    /// right of it rather than sliding underneath. 0 when nothing is
    /// there (every iPhone layout).
    var leadingInset: CGFloat = 0
    /// Which driver is isolated on the map. A binding so the iPad
    /// dispatch split view can drive it from its sidebar list; every
    /// other caller passes its own @State.
    @Binding var selectedDriverId: String?
    /// iPad split view: the sidebar list replaces the chip row.
    var showsLegend = true
    /// iPad split view: fly to the driver when one is picked from outside
    /// the map (the sidebar), instead of leaving the camera where it was.
    var focusesOnSelection = false

    @ObservedObject private var access = FeatureAccessManager.shared

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
            span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
        )
    )

    // driverId -> that driver's active route stops, in route order.
    // Loaded via a live listener per driver (see loadStopsIfNeeded),
    // so a stop turning gray as it's completed happens automatically
    // without the owner needing to refresh anything.
    @State private var stopsByDriver: [String: [Stop]] = [:]
    @State private var routesByDriver: [String: Route] = [:]
    @State private var subscribedDriverIds: Set<String> = []
    @State private var selectedDriverShift: Shift?
    /// What the map is actually showing, so the zoom buttons have a
    /// span to scale - cameraPosition is often not a plain region.
    @State private var visibleRegion: MKCoordinateRegion?

    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()
    private let driverRepo: DriverRepository = FirestoreDriverRepository()
    private let locationAuthorizer = OwnerLocationAuthorizer()

    // THE MAP IS NOT THE PAID FEATURE. The FLEET is.
    //
    // This used to replace the entire map with an upgrade wall on
    // Starter, which made a padlock the first thing a free owner saw
    // every time they opened the app - as their home screen. It was
    // also pointless as a gate: Starter is one driver on one route, and
    // a "fleet map" of one truck is just a map. There was nothing being
    // withheld except the ability to see your own morning.
    //
    // So everyone gets the map. What Premium buys is the fleet: the
    // driver filter pills, and the ability to have more than one truck
    // on it in the first place (see driverLimit). A solo operator sees
    // their own route and their own position; an owner with a crew sees
    // all of them and can isolate one.
    var body: some View {
        map
    }

    private var visibleDrivers: [Driver] {
        driverVM.drivers.filter { $0.coordinate != nil }
    }

    private var map: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                UserAnnotation()

                ForEach(visibleDrivers) { driver in
                    if selectedDriverId == nil || selectedDriverId == driver.id {
                        // Title deliberately EMPTY, like every other annotation on
                        // this map. driverPin draws the driver's name itself,
                        // in a capsule under the dot - passing it here as well
                        // made MapKit render its own label underneath that one,
                        // so every truck on the fleet map was labelled twice.
                        Annotation("", coordinate: driver.coordinate!) {
                            driverPin(driver)
                                .onTapGesture {
                                    selectDriver(driver.id)
                                }
                        }

                        let stops = stopsByDriver[driver.id] ?? []
                        let route = routesByDriver[driver.id]
                        let startCoordinate = route?.startCoordinate
                        let endCoordinate = route?.endCoordinate

                        // Full path including the explicit depot legs
                        // when set, so the line actually shows the
                        // drive to/from them instead of just the
                        // stops in between.
                        let fullPath = ([startCoordinate] + stops.compactMap { $0.coordinate } + [endCoordinate]).compactMap { $0 }
                        if fullPath.count > 1 {
                            MapPolyline(coordinates: fullPath)
                                .stroke(driver.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        }

                        if let startCoordinate {
                            Annotation("", coordinate: startCoordinate) {
                                endpointPin(systemImage: "flag.fill", color: .green)
                            }
                        }

                        ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                            if let coordinate = stop.coordinate {
                                Annotation("", coordinate: coordinate) {
                                    numberedStopPin(index: index + 1, color: driver.color, completed: stop.isCompleted)
                                }
                            }
                        }

                        if let endCoordinate {
                            Annotation("", coordinate: endCoordinate) {
                                endpointPin(systemImage: "flag.checkered", color: .red)
                            }
                        }
                    }
                }
            }
            // Only the sides/bottom bleed full-screen. Leaving the top
            // safe area alone is what actually keeps MapKit's
            // auto-placed controls (MapUserLocationButton included)
            // below the status bar - letting the map extend under the
            // top too (even with .mapControls applied afterward) still
            // let those controls creep up into the battery/wifi icons.
            .ignoresSafeArea(edges: [.horizontal, .bottom])
            .onMapCameraChange { context in
                visibleRegion = context.region
            }
            // MapUserLocationButton is gone from here on purpose - the
            // control column below replaces it, so the owner map works
            // exactly like the driver map instead of having Apple's
            // button in one place and ours in another. Compass and
            // scale stay; they place themselves and don't overlap.
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            // Bottom-trailing, not vertically centred. Centred put the
            // locate button squarely behind the "Dashboard" panel the
            // moment it slid up (and near the selected-driver card),
            // hiding the one control a dispatcher reaches for. Anchored
            // low on the right with clearance below, it stays clear of
            // the collapsed drawer, the open panel and the driver card -
            // and reads like every other map app.
            .overlay(alignment: .bottomTrailing) {
                mapControlColumn
                    .padding(.bottom, controlColumnBottomPadding)
            }

            // The pills are the actual fleet feature - picking one
            // truck out of several. With a single driver there is
            // nothing to pick between, so on Starter they would be an
            // "All" chip next to one name: clutter over the map rather
            // than a capability. Hidden rather than locked, because a
            // padlock over a control that would do nothing anyway
            // reads as a smaller app, not a bigger upsell.
            if showsLegend && access.canAccessLiveFleetMap() {
                driverLegend
            }

            if let selectedDriverId, let driver = visibleDrivers.first(where: { $0.id == selectedDriverId }) {
                driverDetailCard(driver: driver)
                    .padMaxWidth(480)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.leading, leadingInset)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedDriverId)
            }
        }
        .onAppear {
            locationAuthorizer.requestIfNeeded()
            driverVM.startLiveUpdates()
            loadStopsIfNeeded()
        }
        .onChange(of: driverVM.drivers.count) { _, _ in
            loadStopsIfNeeded()
            fitCameraToDriversIfNeeded()
        }
        .onChange(of: visibleDrivers.map(\.id)) { _, _ in
            fitCameraToDriversIfNeeded()
        }
        .onChange(of: selectedDriverId) { _, id in
            loadShift(for: id)
            if focusesOnSelection { focusCamera(on: id) }
        }
    }

    private func focusCamera(on id: String?) {
        guard let id, let coordinate = visibleDrivers.first(where: { $0.id == id })?.coordinate else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
                )
            )
        }
    }

    // Starts centered on a placeholder Toronto coordinate that means
    // nothing for a real company - recenters on the fleet's actual
    // live positions the first time any arrive, so opening this
    // screen doesn't require panning/zooming to find your own trucks.
    // Only runs once (hasCenteredOnFleet) so it doesn't fight the
    // owner's own manual pan/zoom afterward.
    @State private var hasCenteredOnFleet = false
    private func fitCameraToDriversIfNeeded() {
        guard !hasCenteredOnFleet else { return }
        let coordinates = visibleDrivers.compactMap { $0.coordinate }
        guard !coordinates.isEmpty else { return }
        hasCenteredOnFleet = true

        let lats = coordinates.map(\.latitude)
        let lngs = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lngs.min()! + lngs.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.05, (lats.max()! - lats.min()!) * 1.6),
            longitudeDelta: max(0.05, (lngs.max()! - lngs.min()!) * 1.6)
        )
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    // MARK: - Driver pin (live GPS position)

    // How far up from the physical bottom the control column sits (the
    // map bleeds under the tab bar via ignoresSafeArea, so this must
    // clear it itself):
    //  - base: tab bar (~49) + home indicator (~34) + a small gap.
    //  - selectedLift: above the selected-driver detail card.
    //  - bottomInset: above the Dashboard panel when the caller opens it.
    // Whichever obstruction is tallest wins, so the locate button is
    // always fully visible and tappable.
    private var controlColumnBottomPadding: CGFloat {
        let base: CGFloat = 100
        let selectedLift: CGFloat = selectedDriverId != nil ? 200 : 0
        return max(base, max(selectedLift, bottomInset))
    }

    // Right edge, low where a thumb rests rather than a top corner level
    // with the Dynamic Island (which swallows touches). Zoom buttons sit
    // with the locate button because pinching needs two hands; pinch
    // still works, these are the one-handed version.
    private var mapControlColumn: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                Button { zoom(by: 0.5) } label: { controlGlyph("plus") }
                Divider().frame(width: 30).overlay(Color.black.opacity(0.15))
                Button { zoom(by: 2.0) } label: { controlGlyph("minus") }
            }
            .background(Color("WRThemeGold"))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 6)

            Button {
                cameraPosition = .userLocation(fallback: .automatic)
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

    private func controlGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.black)
            .frame(width: 46, height: 44)
            .contentShape(Rectangle())
    }

    /// Clamped so repeated taps can't invert the span or pass world
    /// scale, both of which MapKit draws as a grey rectangle.
    private func zoom(by factor: Double) {
        guard let region = visibleRegion else { return }
        let latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.0008), 120)
        let longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.0008), 120)
        withAnimation(.easeInOut(duration: 0.2)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: region.center,
                    span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
                )
            )
        }
    }

    private func driverPin(_ driver: Driver) -> some View {
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

    // MARK: - Route endpoint pin (explicit start/end, when the route has one set)
    private func endpointPin(systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.caption.bold())
            .foregroundColor(.white)
            .frame(width: 24, height: 24)
            .background(color)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 2)
    }

    // MARK: - Numbered stop pin (route order, dims once completed)
    private func numberedStopPin(index: Int, color: Color, completed: Bool) -> some View {
        Text("\(index)")
            .font(.caption2.bold())
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .background(completed ? Color.gray : color)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .opacity(completed ? 0.55 : 1)
            .shadow(color: .black.opacity(0.35), radius: 2)
    }

    // MARK: - Driver legend / selector
    private var driverLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                legendChip(title: "All", color: .white, isSelected: selectedDriverId == nil) {
                    selectedDriverId = nil
                }

                ForEach(visibleDrivers) { driver in
                    legendChip(
                        title: driver.name,
                        color: driver.color,
                        isSelected: selectedDriverId == driver.id,
                        stopCount: stopsByDriver[driver.id]?.count
                    ) {
                        selectDriver(driver.id)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private func legendChip(title: String, color: Color, isSelected: Bool, stopCount: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(title)
                    .font(.footnote.bold())
                if let stopCount, stopCount > 0 {
                    Text("\(stopCount)")
                        .font(.caption2.bold())
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(color)
                        .clipShape(Capsule())
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.black.opacity(0.85) : Color.black.opacity(0.55))
            .overlay(
                Capsule().stroke(isSelected ? color : Color.clear, lineWidth: 2)
            )
            .clipShape(Capsule())
        }
    }

    // MARK: - Driver selection (pin tap or legend chip - same action)
    private func selectDriver(_ id: String) {
        selectedDriverId = selectedDriverId == id ? nil : id
    }

    private func loadShift(for id: String?) {
        selectedDriverShift = nil
        guard let id else { return }
        driverRepo.fetchActiveShift(driverId: id) { shift in
            Task { @MainActor in
                // Only apply if the owner hasn't already tapped a
                // different driver while this fetch was in flight.
                if selectedDriverId == id { selectedDriverShift = shift }
            }
        }
    }

    // MARK: - Driver detail card
    // What "select a driver, view timing" actually means for an
    // owner - not just a colored dot, but the same at-a-glance status
    // (shift length, current stop, time at that property) the driver
    // themselves sees on their own dashboard.
    private func driverDetailCard(driver: Driver) -> some View {
        let stops = stopsByDriver[driver.id] ?? []
        let currentStop = stops.first { $0.isPending }
        let stopPosition = currentStop.flatMap { stop in stops.firstIndex(where: { $0.id == stop.id }).map { ($0 + 1, stops.count) } }
        let isWorking = selectedDriverShift?.isActive ?? false

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(driver.color).frame(width: 10, height: 10)
                Text(driver.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Text(isWorking ? "🟢 Working" : "⚪️ Off shift")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.8))
            }

            if let route = routesByDriver[driver.id] {
                Text(route.name)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }

            if let currentStop, let stopPosition {
                Text("Stop \(stopPosition.0) of \(stopPosition.1)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                Text(currentStop.address)
                    .font(.subheadline)
                    .foregroundColor(.white)
            }

            HStack(spacing: 20) {
                if let shift = selectedDriverShift, shift.isActive {
                    detailStat(label: "Shift", value: elapsedText(shift.durationSeconds))
                }
                if let currentStop, currentStop.status == JobStatus.arrived.rawValue, let arrivedAt = currentStop.arrivedAt {
                    detailStat(label: "At Property", value: elapsedText(Int(Date().timeIntervalSince(arrivedAt))))
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.85))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(driver.color.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 10)
        .padding(.horizontal, 16)
    }

    private func detailStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(Color("WRThemeGold"))
        }
    }

    private func elapsedText(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // MARK: - Route/stop loading
    // Subscribes once per driver id (not re-subscribed on every GPS
    // ping, which would otherwise fire on nearly every frame) - only
    // fires for genuinely new drivers appearing in the roster.
    private func loadStopsIfNeeded() {
        for driver in visibleDrivers where !subscribedDriverIds.contains(driver.id) {
            subscribedDriverIds.insert(driver.id)
            routeRepo.fetchRouteForDriver(driverId: driver.id) { route in
                guard let route else { return }
                Task { @MainActor in
                    routesByDriver[driver.id] = route
                }
                stopsRepo.loadStops(forRoute: route.id) { stops in
                    Task { @MainActor in
                        stopsByDriver[driver.id] = stops.sorted { $0.order < $1.order }
                    }
                }
            }
        }
    }
}
