import Foundation
import MapKit
import UIKit

final class NavigationService {

    // MARK: - Open in Apple Maps
    static func openInAppleMaps(_ coordinate: CLLocationCoordinate2D, name: String = "Destination") {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        item.openInMaps()
    }

    // MARK: - Open in Google Maps
    static func openInGoogleMaps(_ coordinate: CLLocationCoordinate2D) {
        let url = URL(string: "comgooglemaps://?daddr=\(coordinate.latitude),\(coordinate.longitude)&directionsmode=driving")

        if let url = url, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            print("[NavigationService] Google Maps not installed.")
        }
    }

    // MARK: - Open in Waze
    static func openInWaze(_ coordinate: CLLocationCoordinate2D) {
        let url = URL(string: "waze://?ll=\(coordinate.latitude),\(coordinate.longitude)&navigate=yes")

        if let url = url, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            print("[NavigationService] Waze not installed.")
        }
    }

    // MARK: - Navigate to a Coordinate
    static func navigate(to coordinate: CLLocationCoordinate2D) {
        openInAppleMaps(coordinate)  // default navigation
    }

    // MARK: - Navigate to a Stop
    static func navigate(to stop: Stop) {
        guard let coordinate = stop.coordinate else { return }
        openInAppleMaps(coordinate)  // default navigation
    }
}
