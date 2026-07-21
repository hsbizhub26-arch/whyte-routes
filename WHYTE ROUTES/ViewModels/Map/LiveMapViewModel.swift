//
//  LiveMapView.swift
//  WHYTE ROUTES
//
//  Combined Driver + Manager + Customer Map
//

import SwiftUI
import MapKit
import FirebaseFirestore

@MainActor
final class LiveMapViewModel: ObservableObject {

    // MARK: - Published
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.7, longitude: -79.4),
        span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )

    @Published var driverMarkers: [Driver] = []
    @Published var routeStops: [Stop] = []
    @Published var customerStop: Stop?       // For customer tracking
    @Published var selectedDriver: Driver?
    @Published var isCustomerMode = false
    @Published var isManagerMode = false

    private let db = Firestore.firestore()
    private let session = DriverSession.shared
    private let routeService = RouteService.shared

    private var listener: ListenerRegistration?

    init() {
        determineMode()
        startListeners()
    }

    // MARK: - Determine Role (Driver / Manager / Customer)
    func determineMode() {
        if let role = session.role {
            switch role {
            case .driver:
                isCustomerMode = false
                isManagerMode = false
                loadDriverStops()

            case .manager, .owner:
                isCustomerMode = false
                isManagerMode = true
                listenToAllDrivers()

            case .customer:
                isCustomerMode = true
                isManagerMode = false

            default:
                break
            }
        }
    }

    // MARK: - DRIVER MODE
    func loadDriverStops() {
        guard let driver = session.driver else { return }
        routeStops = routeService.stopsForDriver(driver)
    }

    // MARK: - MANAGER MODE
    func listenToAllDrivers() {
        listener?.remove()

        listener = db.collection("drivers").addSnapshotListener { snap, _ in
            let list = snap?.documents.compactMap { doc in
                Driver(from: doc.data(), id: doc.documentID)
            } ?? []

            self.driverMarkers = list
        }
    }

    // MARK: - CUSTOMER MODE
    func startCustomerTracking(for link: TrackingLink) {
        isCustomerMode = true

        // customer stop location
        let stop = Stop(
            id: link.stopId,
            address: link.address,
            latitude: link.latitude,
            longitude: link.longitude,
            customerName: link.customerName
        )
        self.customerStop = stop

        // listen to single driver
        listener?.remove()
        listener = db.collection("drivers")
            .document(link.driverId)
            .addSnapshotListener { snap, _ in
                guard let data = snap?.data() else { return }
                if let driver = Driver(from: data, id: snap!.documentID) {
                    self.driverMarkers = [driver]
                }
            }
    }

    // MARK: - Clean up
    deinit {
        listener?.remove()
    }

    // MARK: - Map Helpers
    func centerOnDriver() {
        if let driver = driverMarkers.first,
           let coord = driver.coordinate {
            region.center = coord
        }
    }
}

struct LiveMapView: View {

    @StateObject private var vm = LiveMapViewModel()

    var body: some View {
        ZStack {
            mapLayer
            roleButtons
            driverSheet
        }
        .ignoresSafeArea()
    }

    // MARK: - MAP UI
    private var mapLayer: some View {
        Map(coordinateRegion: $vm.region,
            showsUserLocation: !vm.isManagerMode && !vm.isCustomerMode,
            annotationItems: annotationItems
        ) { item in

            MapAnnotation(coordinate: item.coordinate) {
                annotationView(item)
                    .onTapGesture {
                        if let d = item as? Driver {
                            vm.selectedDriver = d
                        }
                    }
            }
        }
    }

    // Combined list of items:
    private var annotationItems: [MapIdentifiable] {
        var items: [MapIdentifiable] = []

        // DRIVER MODE: stops + driver
        if !vm.isManagerMode && !vm.isCustomerMode {
            if let driver = vm.session.driver, let coord = driver.coordinate {
                items.append(MapDriverIdentifiable(driver: driver))
            }
            items.append(contentsOf: vm.routeStops.map { MapStopIdentifiable(stop: $0) })
        }

        // MANAGER MODE: all drivers
        if vm.isManagerMode {
            items.append(contentsOf: vm.driverMarkers.map { MapDriverIdentifiable(driver: $0) })
        }

        // CUSTOMER MODE: 1 driver + 1 stop
        if vm.isCustomerMode {
            if let driver = vm.driverMarkers.first {
                items.append(MapDriverIdentifiable(driver: driver))
            }
            if let stop = vm.customerStop {
                items.append(MapStopIdentifiable(stop: stop))
            }
        }

        return items
    }

    // MARK: - Annotation Rendering
    @ViewBuilder
    func annotationView(_ item: MapIdentifiable) -> some View {
        if let driverItem = item as? MapDriverIdentifiable {
            VStack(spacing: 2) {
                Circle()
                    .fill(Color(hex: driverItem.driver.colorHex ?? "F5C451"))
                    .frame(width: 22, height: 22)
                    .shadow(radius: 8)

                Text(driverItem.driver.name)
                    .font(.caption2)
                    .foregroundColor(.white)
            }
        }
        else if let stopItem = item as? MapStopIdentifiable {
            VStack(spacing: 2) {
                Circle()
                    .fill(Color("WRThemeGold"))
                    .frame(width: 18, height: 18)
                    .shadow(radius: 6)

                Text(stopItem.stop.customerName ?? "")
                    .font(.caption2)
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: - DRIVER INFO SHEET (Manager Mode)
    private var driverSheet: some View {
        Group {
            if let driver = vm.selectedDriver {
                EmptyView()
                    .sheet(item: Binding<Driver?>(
                        get: { vm.selectedDriver },
                        set: { vm.selectedDriver = $0 }
                    )) { d in
                        VStack(spacing: 16) {
                            Text(d.name)
                                .font(.title.bold())
                                .padding(.top)

                            Text("Vehicle: \(d.vehicle)")
                            Text("Last Updated:")
                            Text(TimestampFormatter.shared.asTimeAgo(d.lastUpdated ?? Date()))

                            Spacer()
                        }
                        .padding()
                    }
            }
        }
    }

    // MARK: - BUTTONS
    private var roleButtons: some View {
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
}
