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

    // DELETE. There was no way to remove a route at all. Swipe left on a
    // row (or use Delete Route inside it); always confirmed, because it
    // takes the route's stops, photos and history with it.
    @State private var routePendingDelete: Route?
    @State private var deleteError: String?
    @State private var isDeleting = false
    private let routeRepo = RouteRepository()

    var body: some View {
        NavigationStack {
            List(routeService.routes) { route in
                NavigationLink(route.name) {
                    EditRouteView(routeId: route.id)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        routePendingDelete = route
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .readableListWidth()
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
            .confirmationDialog(
                "Delete \"\(routePendingDelete?.name ?? "route")\"?",
                isPresented: Binding(
                    get: { routePendingDelete != nil },
                    set: { if !$0 { routePendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Route", role: .destructive) {
                    if let route = routePendingDelete { delete(route) }
                }
                Button("Cancel", role: .cancel) { routePendingDelete = nil }
            } message: {
                Text("This removes the route and all its stops, photos and notification history, and closes any customer tracking links for it. Your customers themselves are not deleted. This can't be undone.")
            }
            .alert("Couldn't delete route", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .overlay {
                if isDeleting {
                    ProgressView("Deleting…")
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.85)))
                }
            }
            .onAppear { routeService.loadRoutesOnce() }
            .onChange(of: showCreateRoute) { _, isShowing in
                if !isShowing { routeService.loadRoutesOnce() }
            }
        }
    }

    private func delete(_ route: Route) {
        routePendingDelete = nil
        isDeleting = true
        Task {
            do {
                try await routeRepo.deleteRoute(routeId: route.id)
                await MainActor.run {
                    isDeleting = false
                    routeService.loadRoutesOnce()
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    deleteError = error.localizedDescription
                }
            }
        }
    }
}
