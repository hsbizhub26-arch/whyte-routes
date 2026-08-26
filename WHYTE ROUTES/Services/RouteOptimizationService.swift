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
// startCoordinate/endCoordinate are optional explicit route
// endpoints (Route.startLocation/endLocation) - a depot, the owner's
// shop, wherever the crew's day actually begins/ends, which isn't
// necessarily one of the stops themselves. When nil, behavior is
// unchanged from before this existed: the first stop stays fixed as
// the start, and the route just ends wherever the last stop lands.
enum RouteOptimizationService {

    static func optimize(
        _ stops: [Stop],
        startCoordinate: CLLocationCoordinate2D? = nil,
        endCoordinate: CLLocationCoordinate2D? = nil
    ) -> [Stop] {
        // Stops without coordinates can't be placed in a distance-based
        // order - leave them at the end, untouched, rather than
        // guessing or dropping them.
        let anchored = stops.filter { $0.coordinate != nil }
        let unplaceable = stops.filter { $0.coordinate == nil }

        guard anchored.count > 2 else { return stops }

        var remaining = anchored
        var ordered: [Stop] = []
        var cursor: CLLocationCoordinate2D

        if let startCoordinate {
            // A real depot/start point was given - every stop,
            // including what used to be "the first one", is fair
            // game for reordering.
            cursor = startCoordinate
        } else {
            // No explicit start - same behavior as before this
            // existed: whatever's first in the list stays first.
            let first = remaining.removeFirst()
            ordered.append(first)
            cursor = first.coordinate!
        }

        // Nearest-neighbor construction
        while !remaining.isEmpty {
            let nearestIndex = remaining.indices.min { a, b in
                distance(cursor, remaining[a].coordinate!) < distance(cursor, remaining[b].coordinate!)
            }!
            let next = remaining.remove(at: nearestIndex)
            ordered.append(next)
            cursor = next.coordinate!
        }

        // 2-opt improvement: repeatedly reverse a segment if doing so
        // shortens the total route, until no single swap helps. The
        // lower bound stays 0 when there's an explicit start point
        // (the first stop is no longer fixed) and 1 otherwise. The
        // trailing edge cost folds in the explicit end point when one
        // exists, so a reversal that would leave the route farther
        // from where it actually needs to finish is correctly scored
        // as worse, not ignored.
        let lowerBound = startCoordinate != nil ? 0 : 1
        var improved = true
        while improved {
            improved = false
            for i in lowerBound..<(ordered.count - 1) {
                for j in (i + 1)..<ordered.count {
                    let a = ordered[i - 1].coordinate!
                    let b = ordered[i].coordinate!
                    let c = ordered[j].coordinate!
                    let isLastSegment = j == ordered.count - 1

                    let dCost: CLLocationDistance
                    let swappedDCost: CLLocationDistance
                    if isLastSegment {
                        dCost = endCoordinate.map { distance(c, $0) } ?? 0
                        swappedDCost = endCoordinate.map { distance(b, $0) } ?? 0
                    } else {
                        let d = ordered[j + 1].coordinate!
                        dCost = distance(c, d)
                        swappedDCost = distance(b, d)
                    }

                    let currentLength = distance(a, b) + dCost
                    let swappedLength = distance(a, c) + swappedDCost

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
    /// Includes the explicit start/end legs when those are set, so
    /// the number shown actually reflects the crew's full day.
    static func totalDistanceKM(
        _ stops: [Stop],
        startCoordinate: CLLocationCoordinate2D? = nil,
        endCoordinate: CLLocationCoordinate2D? = nil
    ) -> Double {
        let coords = stops.compactMap { $0.coordinate }
        guard !coords.isEmpty else { return 0 }

        var total = 0.0
        if let startCoordinate, let first = coords.first {
            total += distance(startCoordinate, first) / 1000
        }
        if coords.count > 1 {
            for i in 0..<(coords.count - 1) {
                total += distance(coords[i], coords[i + 1]) / 1000
            }
        }
        if let endCoordinate, let last = coords.last {
            total += distance(last, endCoordinate) / 1000
        }
        return total
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
