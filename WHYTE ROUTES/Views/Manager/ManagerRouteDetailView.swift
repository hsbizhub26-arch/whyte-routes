import SwiftUI

struct ManagerRouteDetailView: View {

    var route: Route

    var body: some View {
        VStack(spacing: 20) {
            Text("Route Detail")
                .font(.largeTitle.bold())

            Text("Name: \(route.name)")
                .foregroundColor(.gray)

            Text("More route details go here…")

            Spacer()
        }
        .padding()
    }
}
