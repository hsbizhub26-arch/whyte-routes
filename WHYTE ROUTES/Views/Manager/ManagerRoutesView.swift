import SwiftUI

struct ManagerRoutesView: View {

    @StateObject private var vm = RoutesViewModel()

    @State private var selectedRoute: Route?
    @State private var showAssignSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {

                Text("All Routes")
                    .font(.largeTitle.bold())
                    .foregroundColor(Color.yellow)
                    .padding(.horizontal)

                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(vm.routes) { route in
                            ManagerRouteCard(route: route) {
                                selectedRoute = route
                            } assignDriverAction: {
                                selectedRoute = route
                                showAssignSheet = true
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
        }
        .sheet(isPresented: $showAssignSheet) {
            if let route = selectedRoute {
                ManagerAssignDriverSheet(route: route)
            }
        }
        .sheet(item: $selectedRoute) { route in
            ManagerRouteDetailView(route: route)
        }
    }
}
