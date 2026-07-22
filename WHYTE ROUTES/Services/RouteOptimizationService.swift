import Foundation
import CoreLocation

// Reorders a route's stops into a shorter driving order. Deliberately
// NOT a full Vehicle Routing Problem solver (that needs something
// like Google OR-Tools or a paid routing API - real infrastructure,
// out of scope) - this is nearest-neighbor construction + 2-opt
// improvement, a well-established heuristic that gets close to
// optimal for the stop counts a crew actually runs (dozens, not
// thousands), computed entirely on-device from straight-line
// distance. No network call, no API key, no per-request cost.
//
// The first stop in the list is treated as the fixed starting point
// (wherever the route currently begins) and never moved - only the
// stops after it get reordered. Manual drag-to-reorder (EditRouteView)
// still works on the result; this is a starting point to adjust from,
// not a lock.
enum RouteOptimizationService {

    static func optimize(_ stops: [Stop]) -> [Stop] {
        // Stops without coordinates can't be placed in a distance-based
        // order - leave them at the end, untouched, rather than
        // guessing or dropping them.
        let anchored = stops.filter { $0.coordinate != nil }
        let unplaceable = stops.filter { $0.coordinate == nil }

        guard anchored.count > 2 else { return stops }

        var remaining = Array(anchored.dropFirst())
        var ordered = [anchored[0]]

        // Nearest-neighbor construction
        while !remaining.isEmpty {
            let current = ordered.last!.coordinate!
            let nearestIndex = remaining.indices.min { a, b in
                distance(current, remaining[a].coordinate!) < distance(current, remaining[b].coordinate!)
            }!
            ordered.append(remaining.remove(at: nearestIndex))
        }

        // 2-opt improvement: repeatedly reverse a segment if doing so
        // shortens the total route, until no single swap helps.
        var improved = true
        while improved {
            improved = false
            for i in 1..<(ordered.count - 1) {
                for j in (i + 1)..<ordered.count {
                    let a = ordered[i - 1].coordinate!
                    let b = ordered[i].coordinate!
                    let c = ordered[j].coordinate!
                    let d = j + 1 < ordered.count ? ordered[j + 1].coordinate! : nil

                    let currentLength = distance(a, b) + (d != nil ? distance(c, d!) : 0)
                    let swappedLength = distance(a, c) + (d != nil ? distance(b, d!) : 0)

                    if swappedLength < currentLength {
                        ordered[i...j].reverse()
                        improved = true
                    }
                }
            }
        }

        return ordered + unplaceable
    }

    /// Total straight-line distance of the route in the given order,
    /// in kilometers - an approximation (not actual driving distance,
    /// no roads/traffic considered), labeled as such wherever shown.
    static func totalDistanceKM(_ stops: [Stop]) -> Double {
        let coords = stops.compactMap { $0.coordinate }
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 0..<(coords.count - 1) {
            total += distance(coords[i], coords[i + 1]) / 1000
        }
        return total
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
