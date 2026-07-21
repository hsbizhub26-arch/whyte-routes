import Foundation
import MapKit
import CoreLocation

final class MapboxService {

    static let shared = MapboxService()
    private init() {}

    // 🌎 Your Mapbox token
    let accessToken = "pk.eyJ1Ijoicm91dGVnb2VzMSIsImEiOiJjbWlkenM2c3IwYXpwMmluMzF1M2ozcWhiIn0.8j6Gxpu-9iauVFt_NIepFA"

    // MARK: - Convert address → location
    func geocode(_ address: String, completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        CLGeocoder().geocodeAddressString(address) { placemarks, error in
            completion(placemarks?.first?.location?.coordinate)
        }
    }

    // MARK: - Straight-line distance
    func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return a.distance(from: b)
    }

    // MARK: - ETA using MapKit
    func estimatedTime(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        completion: @escaping (TimeInterval?) -> Void
    ) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile

        MKDirections(request: request).calculateETA { response, error in
            completion(response?.expectedTravelTime)
        }
    }
}
