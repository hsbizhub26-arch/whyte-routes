import SwiftUI
import MapKit

struct MapScreen: View {
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $position) {
            // Placeholder: show user location when available
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .realistic))
        .overlay(alignment: .topLeading) {
            Text("MAP")
                .font(.caption).padding(6)
                .background(Color.black.opacity(0.7))
                .foregroundColor(.yellow)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding()
        }
    }
}

#Preview {
    MapScreen()
}
