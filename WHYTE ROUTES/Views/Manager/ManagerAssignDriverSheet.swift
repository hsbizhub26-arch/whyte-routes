import SwiftUI

struct ManagerAssignDriverSheet: View {

    var route: Route

    var body: some View {
        VStack(spacing: 20) {
            Text("Assign Driver")
                .font(.title.bold())

            Text("Route: \(route.name)")
                .foregroundColor(.gray)

            Text("Driver picker goes here…")

            Spacer()
        }
        .padding()
    }
}
