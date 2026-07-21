import SwiftUI
import MapKit

struct ManagerDriverListView: View {

    @StateObject private var driversVM = DriverViewModel()
    @State private var searchText = ""
    @State private var selectedDriver: Driver?

    var filteredDrivers: [Driver] {
        if searchText.isEmpty { return driversVM.drivers }
        return driversVM.drivers.filter {
            $0.name.lowercased().contains(searchText.lowercased()) ||
            ($0.phone ?? "").contains(searchText)
        }
    }

    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            VStack(spacing: 0) {

                header

                Divider().background(Color("WRThemeGold").opacity(0.6))

                searchBar

                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(filteredDrivers) { driver in
                            driverCard(driver)
                                .onTapGesture {
                                    selectedDriver = driver
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $selectedDriver) { driver in
            ManagerDriverDetailView(driver: driver)
        }
        .navigationBarHidden(true)
    }
}

extension ManagerDriverListView {

    // MARK: HEADER
    private var header: some View {
        HStack {
            Text("Drivers")
                .foregroundColor(Color("WRThemeGold"))
                .font(.largeTitle.bold())
            Spacer()
        }
        .padding()
    }

    // MARK: SEARCH BAR
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color("WRThemeGold"))

            TextField("Search drivers...", text: $searchText)
                .foregroundColor(.white)
        }
        .padding()
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    // MARK: DRIVER CARD
    private func driverCard(_ driver: Driver) -> some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack {
                Text(driver.name)
                    .foregroundColor(.white)
                    .font(.headline)

                Spacer()

                Circle()
                    .fill(driver.activeRoute == nil ? .green : .red)
                    .frame(width: 14, height: 14)
            }

            if let routeId = driver.activeRoute {
                Text("Route Assigned: \(routeId)")
                    .foregroundColor(Color("WRThemeGold"))
                    .font(.caption)
            } else {
                Text("No Route Assigned")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.caption)
            }

            if let coord = driver.coordinate {
                Text("Location: \(coord.latitude.rounded()), \(coord.longitude.rounded())")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.caption)
            }

            if let time = driver.lastUpdated {
                Text("Updated: \(TimestampFormatter.shared.asTimeAgo(time))")
                    .foregroundColor(.white.opacity(0.6))
                    .font(.caption2)
            }
        }
        .padding()
        .background(Color.black.opacity(0.9))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color("WRThemeGold"), lineWidth: 2)
        )
    }
}
