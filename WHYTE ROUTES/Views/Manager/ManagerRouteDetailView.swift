import SwiftUI

// Was a literal placeholder ("More route details go here…"). Rather
// than build a second, separate route-editing screen, this reuses
// EditRouteView - the same real, fully-built screen Owner's
// AssignRoutesView already uses (stops, driver assignment, start/end
// points, optimize route). A manager satisfies isCompanyStaff in the
// Firestore rules exactly the same way an owner does, so nothing
// there needs to change for this to work correctly for both roles.
// No NavigationStack here - EditRouteView's own body already opens
// one; wrapping a second one around it is what produced doubled back
// buttons the last time this happened (see SettingsView).
struct ManagerRouteDetailView: View {

    var route: Route

    var body: some View {
        EditRouteView(routeId: route.id)
    }
}
