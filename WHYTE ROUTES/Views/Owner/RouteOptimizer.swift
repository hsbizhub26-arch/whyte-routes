import Foundation
import CoreLocation

struct RouteStop {
    let id: String
    let coordinate: CLLocationCoordinate2D
}

class RouteOptimizer {

    // Basic nearest-neighbor route optimizer (fast)
    func optimize(stops: [RouteStop], start: CLLocationCoordinate2D) -> [RouteStop] {

        var remaining = stops
        var ordered: [RouteStop] = []

        var current = start

        while !remaining.isEmpty {
            if let nearest = remaining.min(by: {
                distance(from: current, to: $0.coordinate) <
                distance(from: current, to: $1.coordinate)
            }) {
                ordered.append(nearest)
                current = nearest.coordinate
                remaining.removeAll(where: { $0.id == nearest.id })
            }
        }

        return ordered
    }

    // Haversine distance
    private func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let loc2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return loc1.distance(from: loc2)
    }
}

#if DEBUG
import SwiftUI

struct RouteOptimizerDemoView: View {
    @State private var optimizedStops: [RouteStop] = []
    private let sampleStops: [RouteStop] = [
        RouteStop(id: "A", coordinate: .init(latitude: 37.3317, longitude: -122.0307)),
        RouteStop(id: "B", coordinate: .init(latitude: 37.7749, longitude: -122.4194)),
        RouteStop(id: "C", coordinate: .init(latitude: 37.4419, longitude: -122.1430))
    ]
    private let start = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)

    var body: some View {
        VStack(spacing: 16) {
            Button("Optimize Route") {
                let optimizer = RouteOptimizer()
                optimizedStops = optimizer.optimize(stops: sampleStops, start: start)
            }
            List(optimizedStops, id: \.id) { stop in
                VStack(alignment: .leading) {
                    Text("Stop: \(stop.id)")
                    Text("Lat: \(stop.coordinate.latitude), Lng: \(stop.coordinate.longitude)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding()
    }
}

#Preview("Route Optimizer Demo") {
    RouteOptimizerDemoView()
}
#endif
