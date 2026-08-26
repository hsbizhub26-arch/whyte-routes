import SwiftUI
import MapKit

// The live dispatch map - every driver's live GPS position, plus each
// driver's active route drawn as a numbered, color-matched path (the
// inRoute-style numbered-pin-and-line look, but per-driver colored so
// multiple simultaneous routes stay distinguishable on one map instead
// of only ever showing one route at a time). The driver legend at the
// top is the "clean way to see each driver's route" - tap a driver to
// focus their route alone, tap again (or "All") to see the whole fleet.
struct LiveFleetMapView: View {

    @StateObject private var driverVM = DriverViewModel()
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
    @State private var selectedDriverId: String?

    private let routeRepo = RouteRepository()
    private let stopsRepo = StopsRepository()

    var body: some View {
        if access.canAccessLiveFleetMap() {
            map
        } else {
            UpgradeRequiredView(featureName: "Live Fleet Map", requiredTier: access.requiredTierForLiveFleetMap)
        }
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
                        Annotation(driver.name, coordinate: driver.coordinate!) {
                            driverPin(driver)
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
            .mapControls {
                MapCompass()
                MapScaleView()
                MapUserLocationButton()
            }

            driverLegend
        }
        .onAppear {
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
                        selectedDriverId = (selectedDriverId == driver.id) ? nil : driver.id
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
