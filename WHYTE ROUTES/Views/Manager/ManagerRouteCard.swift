import SwiftUI

struct ManagerRouteCard: View {

    var route: Route
    var detailAction: () -> Void
    var assignDriverAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(route.name)
                .font(.headline)
                .foregroundColor(.white)

            HStack {
                Button("Details") { detailAction() }
                    .foregroundColor(.yellow)

                Spacer()

                Button("Assign Driver") { assignDriverAction() }
                    .foregroundColor(.yellow)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.2))
        .cornerRadius(12)
    }
}
