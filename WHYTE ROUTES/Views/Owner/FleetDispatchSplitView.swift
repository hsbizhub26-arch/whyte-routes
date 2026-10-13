import SwiftUI

// iPad dispatch screen: a fleet list down the left, the live map filling
// the rest. Picking a driver in the list isolates them on the map and
// flies the camera to their truck; tapping a pin on the map highlights
// the row. Used by the owner's Home tab and the manager's Live Map tab
// whenever the window is regular width - iPhone and compact iPad keep
// their existing layouts, so this file is never reached from there.
struct FleetDispatchSplitView: View {

    @ObservedObject private var companySession = CompanySession.shared
    @StateObject private var driverVM = DriverViewModel()
    @StateObject private var routeService = RouteService.shared

    @State private var selectedDriverId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var editingRoute: EditableRoute?

    private struct EditableRoute: Identifiable {
        let id: String
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            LiveFleetMapView(
                driverVM: driverVM,
                selectedDriverId: $selectedDriverId,
                showsLegend: false,
                focusesOnSelection: true
            )
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            driverVM.startLiveUpdates()
            routeService.loadRoutesOnce()
        }
        .sheet(item: $editingRoute) { route in
            EditRouteView(routeId: route.id)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section {
                summary
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }

            Section {
                if driverVM.drivers.isEmpty {
                    Text(driverVM.isLoading ? "Loading drivers\u{2026}" : "No drivers yet.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                        .listRowBackground(Color.clear)
                }
                ForEach(driverVM.drivers) { driver in
                    driverRow(driver)
                        .listRowBackground(
                            selectedDriverId == driver.id
                                ? driver.color.opacity(0.18)
                                : WRTheme.softBlack
                        )
                }
            } header: {
                Text("Fleet")
                    .foregroundColor(WRTheme.gold)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(companySession.currentCompany?.name ?? "Dispatch")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var totalStops: Int {
        routeService.routes.reduce(0) { $0 + (routeService.stopsByRoute[$1.id]?.count ?? $1.stops.count) }
    }

    private var completedStops: Int {
        driverVM.drivers.reduce(0) { $0 + routeService.reportFor($1).completedStops }
    }

    private var driversOnRoute: Int {
        driverVM.drivers.filter { !($0.activeRoute ?? "").isEmpty }.count
    }

    private var summary: some View {
        let fraction = totalStops > 0 ? min(1, Double(completedStops) / Double(totalStops)) : 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                summaryStat(value: "\(driverVM.drivers.count)", title: "Drivers")
                summaryStat(value: "\(driversOnRoute)", title: "On Route")
                summaryStat(value: "\(completedStops)/\(totalStops)", title: "Stops")
            }

            ProgressView(value: fraction)
                .tint(WRTheme.gold)

            Text("\(Int((fraction * 100).rounded()))% of today's stops done")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private func summaryStat(value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(WRTheme.softBlack)
        .cornerRadius(10)
    }

    // MARK: - Driver row

    private func route(for driver: Driver) -> Route? {
        routeService.routes.first { $0.driverId == driver.id }
    }

    private func driverRow(_ driver: Driver) -> some View {
        let route = route(for: driver)
        let stops = route.flatMap { routeService.stopsByRoute[$0.id] } ?? []
        let done = stops.filter(\.isCompleted).count
        let hasLocation = driver.coordinate != nil

        return HStack(spacing: 10) {
            Button {
                selectedDriverId = selectedDriverId == driver.id ? nil : driver.id
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(driver.color)
                        .frame(width: 12, height: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(driver.name)
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(route?.name ?? "No route assigned")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                        if !stops.isEmpty {
                            Text("\(done) of \(stops.count) stops")
                                .font(.caption)
                                .foregroundColor(WRTheme.gold)
                        }
                        if !hasLocation {
                            Text("No live location")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let route {
                Button {
                    editingRoute = EditableRoute(id: route.id)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(WRTheme.gold)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(route.name)")
            }
        }
        .padding(.vertical, 4)
    }
}
