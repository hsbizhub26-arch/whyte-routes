import Foundation
import MapKit
import UIKit

/// A service that opens turn-by-turn navigation in popular map apps with sensible fallbacks.
@MainActor
@available(iOSApplicationExtension, unavailable)
final class NavigationService {

    // MARK: - Types
    enum DirectionsMode: String {
        case driving
        case walking
        case transit
        case bicycling

        // Mapping to Apple Maps MKLaunchOptionsDirectionsMode
        var appleMapsMode: String {
            switch self {
            case .driving: return MKLaunchOptionsDirectionsModeDriving
            case .walking: return MKLaunchOptionsDirectionsModeWalking
            case .transit: return MKLaunchOptionsDirectionsModeTransit
            case .bicycling:
                // Apple Maps has no dedicated bicycling mode; fall back to walking
                return MKLaunchOptionsDirectionsModeWalking
            }
        }

        // Mapping to Google Maps URL parameter
        var googleMapsMode: String {
            switch self {
            case .driving: return "driving"
            case .walking: return "walking"
            case .transit: return "transit"
            case .bicycling: return "bicycling"
            }
        }

        // Mapping to Waze is implicit; Waze doesn't expose mode in URL, defaults to driving
    }

    enum MapApp: String {
        case appleMaps
        case googleMaps
        case waze
    }

    // MARK: - Public API

    /// Opens Apple Maps to the specified coordinate.
    /// - Parameters:
    ///   - coordinate: Destination coordinate.
    ///   - name: A display name for the destination.
    ///   - mode: Directions mode; defaults to driving.
    static func openInAppleMaps(_ coordinate: CLLocationCoordinate2D, name: String = "Destination", mode: DirectionsMode = .driving) {
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = name
        let launchOptions: [String: Any] = [MKLaunchOptionsDirectionsModeKey: mode.appleMapsMode]
        item.openInMaps(launchOptions: launchOptions)
    }

    /// Opens Google Maps if installed, otherwise attempts to open the web fallback.
    /// - Parameters:
    ///   - coordinate: Destination coordinate.
    ///   - name: Optional destination name used for web fallback.
    ///   - mode: Directions mode.
    /// - Returns: `true` if the request was initiated, `false` otherwise.
    @discardableResult
    static func openInGoogleMaps(_ coordinate: CLLocationCoordinate2D, name: String? = nil, mode: DirectionsMode = .driving, avoidTolls: Bool = false, avoidHighways: Bool = false) -> Bool {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        // Google Maps URL scheme supports avoid parameters ("tolls", "highways").
        // Apple Maps and Waze do not expose equivalent options in their external launch APIs.
        var avoid: [String] = []
        if avoidTolls { avoid.append("tolls") }
        if avoidHighways { avoid.append("highways") }
        let avoidParam = avoid.isEmpty ? "" : "&avoid=\(avoid.joined(separator: ","))"

        // App URL scheme
        let appURLString = "comgooglemaps://?daddr=\(lat),\(lon)&directionsmode=\(mode.googleMapsMode)\(avoidParam)"
        guard let appURL = URL(string: appURLString) else {
            print("[NavigationService] Failed to build Google Maps URL.")
            return false
        }

        if UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL, options: [:], completionHandler: nil)
            return true
        }

        // Web fallback
        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        let daddr = "\(lat),\(lon)"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: daddr),
            URLQueryItem(name: "travelmode", value: mode.googleMapsMode)
        ]
        if let name = name, !name.isEmpty {
            // Google Maps' web fallback accepts a plain-text query
            // alongside the lat/lon destination, so the stop's name
            // still shows up even without a real place ID to give it.
            queryItems.append(URLQueryItem(name: "query", value: name))
        }
        if !avoid.isEmpty {
            queryItems.append(URLQueryItem(name: "avoid", value: avoid.joined(separator: ",")))
        }
        components?.queryItems = queryItems

        if let webURL = components?.url {
            UIApplication.shared.open(webURL, options: [:], completionHandler: nil)
            return true
        }

        print("[NavigationService] Google Maps not available and failed to build web URL.")
        return false
    }

    /// Opens Waze if installed; falls back to Apple Maps.
    /// - Returns: `true` if the request was initiated, `false` otherwise.
    @discardableResult
    static func openInWaze(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let urlString = "waze://?ll=\(lat),\(lon)&navigate=yes"
        guard let url = URL(string: urlString) else {
            print("[NavigationService] Failed to build Waze URL.")
            return false
        }

        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return true
        }

        // Waze web fallback opens the location in Waze live map
        if let webURL = URL(string: "https://waze.com/ul?ll=\(lat),\(lon)&navigate=yes") {
            UIApplication.shared.open(webURL, options: [:], completionHandler: nil)
            return true
        }

        print("[NavigationService] Waze not available and failed to build web URL.")
        return false
    }

    /// Navigate to a coordinate using a preferred app with fallbacks.
    /// Note: avoidTolls/avoidHighways are only honored by Google Maps; Apple Maps and Waze ignore them.
    static func navigate(
        to coordinate: CLLocationCoordinate2D,
        name: String = "Destination",
        preferred: MapApp = .appleMaps,
        mode: DirectionsMode = .driving,
        avoidTolls: Bool = false,
        avoidHighways: Bool = false
    ) {
        switch preferred {
        case .appleMaps:
            openInAppleMaps(coordinate, name: name, mode: mode)
        case .googleMaps:
            if !openInGoogleMaps(coordinate, name: name, mode: mode, avoidTolls: avoidTolls, avoidHighways: avoidHighways) {
                // Fallback to Apple Maps
                openInAppleMaps(coordinate, name: name, mode: mode)
            }
        case .waze:
            if !openInWaze(coordinate) {
                // Fallback to Apple Maps
                openInAppleMaps(coordinate, name: name, mode: mode)
            }
        }
    }

    /// Navigate to a Stop model (requires `Stop.coordinate`), applying
    /// the company's own NavigationSettings.
    static func navigate(to stop: Stop, settings: NavigationSettings = NavigationSettings(), mode: DirectionsMode = .driving) {
        guard let coordinate = stop.coordinate else {
            print("[NavigationService] Stop has no coordinate.")
            return
        }
        let name = stop.customerName ?? "Destination"
        let preferred = MapApp(rawValue: settings.preferredProvider) ?? .appleMaps
        navigate(
            to: coordinate,
            name: name,
            preferred: preferred,
            mode: mode,
            avoidTolls: settings.avoidTolls,
            avoidHighways: settings.avoidHighways
        )
    }
}
