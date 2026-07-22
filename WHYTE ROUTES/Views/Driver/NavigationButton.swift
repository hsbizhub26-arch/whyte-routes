import SwiftUI
import CoreLocation

struct NavigationButton: View {

    let coordinate: CLLocationCoordinate2D?

    var body: some View {
        Button {
            if let coordinate {
                let settings = CompanySession.shared.currentCompany?.navigationSettings ?? NavigationSettings()
                let preferred = NavigationService.MapApp(rawValue: settings.preferredProvider) ?? .appleMaps
                NavigationService.navigate(
                    to: coordinate,
                    preferred: preferred,
                    avoidTolls: settings.avoidTolls,
                    avoidHighways: settings.avoidHighways
                )
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
