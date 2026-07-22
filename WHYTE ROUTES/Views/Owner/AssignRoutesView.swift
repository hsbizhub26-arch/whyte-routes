import SwiftUI

struct AssignRoutesView: View {

    @StateObject private var routeService = RouteService.shared
    @State private var showCreateRoute = false

    var body: some View {
        NavigationStack {
            List(routeService.routes) { route in
                NavigationLink(route.name) {
                    AssignRouteView(routeId: route.id)
                }
            }
            .navigationTitle("Assign Routes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateRoute = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showCreateRoute) {
                CreateRouteView()
            }
            .onAppear { routeService.loadRoutesOnce() }
            .onChange(of: showCreateRoute) { _, isShowing in
                if !isShowing { routeService.loadRoutesOnce() }
            }
        }
    }
}

struct AssignRouteView: View {

    let routeId: String
    @State private var drivers: [Driver] = []

    private let driverRepo = FirestoreDriverRepository()
    private let routeRepo = RouteRepository()

    var body: some View {
        List(drivers) { driver in
            Button {
                assignRoute(to: driver)
            } label: {
                VStack(alignment: .leading) {
                    Text(driver.name)
                        .foregroundColor(.primary)
                    Text(driver.vehicle)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .onAppear(perform: loadDrivers)
        .navigationTitle("Assign Driver")
    }

    func loadDrivers() {
        driverRepo.fetchDrivers { result in
            if case .success(let fetched) = result {
                drivers = fetched
            }
        }
    }

    func assignRoute(to driver: Driver) {
        routeRepo.assignDriver(routeId: routeId, driverId: driver.id)
        driverRepo.assignRoute(driverId: driver.id, routeId: routeId)
    }
}
