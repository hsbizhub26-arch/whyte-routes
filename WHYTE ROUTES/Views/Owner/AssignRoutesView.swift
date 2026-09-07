import SwiftUI

struct AssignRoutesView: View {

    @StateObject private var routeService = RouteService.shared
    @State private var showCreateRoute = false
    // The route ceiling had NO enforcement anywhere in the app. The limit
    // existed in FeatureAccessManager and canAddRoute() was never once
    // called, so a free company could build unlimited routes forever -
    // the whole dispatch engine, given away, while the platform paid the
    // Firestore and MapKit bills. Free is a test drive; commercial
    // operations belong behind the paywall.
    @State private var showRouteLimitPaywall = false
    @ObservedObject private var access = FeatureAccessManager.shared

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
                        if access.canAddRoute(currentCount: routeService.routes.count) {
                            showCreateRoute = true
                        } else {
                            showRouteLimitPaywall = true
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showCreateRoute) {
                CreateRouteView()
            }
            .sheet(isPresented: $showRouteLimitPaywall) {
                UpgradeRequiredView(
                    featureName: "More than \(access.routeLimit ?? 1) route",
                    requiredTier: .premium
                )
            }
            .onAppear { routeService.loadRoutesOnce() }
            .onChange(of: showCreateRoute) { _, isShowing in
                if !isShowing { routeService.loadRoutesOnce() }
            }
        }
    }
}
