import SwiftUI

// Same dual-.sheet conflict as ManagerDashboardView had (see that
// file's comment) - two independent .sheet modifiers on one view,
// both triggerable from the same "Assign Driver" tap. Same fix: one
// enum-backed sheet state instead of two separate ones.
private enum ManagerRoutesSheet: Identifiable {
    case routeDetail(Route)
    case assignDriver(Route)

    var id: String {
        switch self {
        case .routeDetail(let route): return "detail-\(route.id)"
        case .assignDriver(let route): return "assign-\(route.id)"
        }
    }
}

struct ManagerRoutesView: View {

    @StateObject private var vm = RoutesViewModel()

    @State private var activeSheet: ManagerRoutesSheet?

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
                                activeSheet = .routeDetail(route)
                            } assignDriverAction: {
                                activeSheet = .assignDriver(route)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .routeDetail(let route):
                ManagerRouteDetailView(route: route)
            case .assignDriver(let route):
                ManagerAssignDriverSheet(route: route)
            }
        }
    }
}
