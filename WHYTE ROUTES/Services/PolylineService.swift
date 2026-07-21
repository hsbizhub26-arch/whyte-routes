import Foundation
import MapKit

/// Creates polylines for mapping between stops and provides map zoom regions.
final class PolylineService {

    static let shared = PolylineService()
    private init() {}

    // MARK: - Create polyline from STOP array
    func polyline(from stops: [Stop]) -> MKPolyline? {
        let coordinates = stops.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }

        guard coordinates.count >= 2 else {
            return nil
        }

        return MKPolyline(coordinates: coordinates, count: coordinates.count)
    }

    // MARK: - Create polyline from coordinate array
    func polyline(from coords: [CLLocationCoordinate2D]) -> MKPolyline? {
        guard coords.count >= 2 else {
            return nil
        }

        return MKPolyline(coordinates: coords, count: coords.count)
    }

    // MARK: - Region to auto-zoom map to show all stops
    func region(for stops: [Stop]) -> MKCoordinateRegion {
        let coords = stops.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }

        return region(for: coords)
    }

    func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard coords.count > 1 else {
            // Single stop → Center map on it
            let coord = coords.first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
            return MKCoordinateRegion(center: coord,
                                      span: MKCoordinateSpan(latitudeDelta: 0.01,
                                                             longitudeDelta: 0.01))
        }

        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        return MKCoordinateRegion(polyline.boundingMapRect)
    }
}
