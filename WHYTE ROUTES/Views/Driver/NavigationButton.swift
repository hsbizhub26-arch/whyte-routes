import SwiftUI
import CoreLocation

struct NavigationButton: View {

    let coordinate: CLLocationCoordinate2D?

    var body: some View {
        Button {
            if let coordinate {
                NavigationService.navigate(to: coordinate)
            }
        } label: {
            Text("Navigate")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.black)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
        .disabled(coordinate == nil)
        .opacity(coordinate == nil ? 0.5 : 1)
    }
}
