import SwiftUI

struct AssignRoutesView: View {

    @StateObject private var routeService = RouteService.shared
    @State private var showCreateRoute = false

    var body: some View {
        NavigationStack {
            List(routeService.routes) { route in
                NavigationLink(route.name) {
                    EditRouteView(routeId: route.id)
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
