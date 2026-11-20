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

        // With an explicit start, even two stops have a better order;
        // without one the first stays fixed, so two can't change.
        guard anchored.count > (startCoordinate != nil ? 1 : 2) else { return anchored + unplaceable }

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

        return twoOpt(ordered, startCoordinate: startCoordinate, endCoordinate: endCoordinate) + unplaceable
    }

    /// 2-opt applied to the order the stops are ALREADY in, with no
    /// nearest-neighbor rebuild. Nearest-neighbor can lose to an order
    /// someone tuned by hand (seen on a real 57-stop route in the B1
    /// test: 60.5 km by hand vs 68.6 km rebuilt), so the preview tries
    /// both and keeps the shorter. Same first-stop rule as optimize().
    static func refine(
        _ stops: [Stop],
        startCoordinate: CLLocationCoordinate2D? = nil,
        endCoordinate: CLLocationCoordinate2D? = nil
    ) -> [Stop] {
        let anchored = stops.filter { $0.coordinate != nil }
        let unplaceable = stops.filter { $0.coordinate == nil }
        guard anchored.count > (startCoordinate != nil ? 1 : 2) else { return anchored + unplaceable }
        return twoOpt(anchored, startCoordinate: startCoordinate, endCoordinate: endCoordinate) + unplaceable
    }

    /// Every stop passed in must have a coordinate.
    private static func twoOpt(
        _ input: [Stop],
        startCoordinate: CLLocationCoordinate2D?,
        endCoordinate: CLLocationCoordinate2D?
    ) -> [Stop] {
        var ordered = input
        guard ordered.count > 1 else { return ordered }

        // 2-opt improvement: repeatedly reverse a segment if doing so
        // shortens the total route, until no single swap helps. The
        // lower bound stays 0 when there's an explicit start point
        // (the first stop is no longer fixed) and 1 otherwise. The
        // trailing edge cost folds in the explicit end point when one
        // exists, so a reversal that would leave the route farther
        // from where it actually needs to finish is correctly scored
        // as worse, not ignored.
        //
        // TERMINATION. A swap must save at least minGain metres, and
        // the number of passes is capped. Stops in a straight line (one
        // street) make many swaps mathematically a tie; with plain `<`
        // floating-point rounding let ties look like gains and the loop
        // could swap forever, freezing the app (found by the B1 random
        // route test). Neither guard changes a real-world result: 10 cm
        // is meaningless on a route, and 2-opt settles in a handful of
        // passes for crew-sized routes.
        let lowerBound = startCoordinate != nil ? 0 : 1
        let minGain: CLLocationDistance = 0.1
        let maxPasses = 200
        var passes = 0
        var improved = true
        while improved && passes < maxPasses {
            passes += 1
            improved = false
            for i in lowerBound..<(ordered.count - 1) {
                for j in (i + 1)..<ordered.count {
                    // The node the reversed segment is entered FROM.
                    // For i > 0 that's the previous stop; for i == 0 -
                    // which only happens when an explicit start point
                    // made the first stop reorderable - it's the depot
                    // itself. Reading ordered[i - 1] unconditionally
                    // meant index -1 on the very first iteration, so
                    // Optimize Route crashed outright for any owner who
                    // had filled in the start-location field.
                    let a: CLLocationCoordinate2D = i > 0
                        ? ordered[i - 1].coordinate!
                        : (startCoordinate ?? ordered[0].coordinate!)
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

                    if swappedLength < currentLength - minGain {
                        ordered[i...j].reverse()
                        improved = true
                    }
                }
            }
        }

        return ordered
    }

    // MARK: - Preview plan (B1)

    /// What Optimize Route would do, computed without touching the
    /// route, so the owner can see it before agreeing to it.
    struct Plan {
        let original: [Stop]
        let proposed: [Stop]
        let beforeKM: Double
        let afterKM: Double
        /// Done, skipped, en-route and arrived stops. They keep their
        /// place at the top - reordering finished driveways back into
        /// the driver's "to do" list mid-shift was the A1 audit bug.
        let lockedCount: Int
        /// Pending stops with no map location - can't be placed by
        /// distance, so they stay at the end, and the owner is told.
        let unplaceableCount: Int
        /// B8: the current order has time-window stops out of window
        /// order and the proposal fixes that (even if it costs distance).
        var windowOrderFixed: Bool = false
        /// B8: windowed stops estimated to arrive after their window
        /// closes in the PROPOSED order (rough estimate).
        var windowRisks: [Stop] = []

        var changesOrder: Bool { proposed.map(\.id) != original.map(\.id) }
        var savedKM: Double { max(0, beforeKM - afterKM) }
    }

    /// A stop the optimizer must leave where it is: finished, skipped,
    /// or the one the crew is driving to / standing at right now.
    static func isLocked(_ stop: Stop) -> Bool {
        if !stop.isPending { return true }
        return stop.status == JobStatus.enRoute.rawValue || stop.status == JobStatus.arrived.rawValue
    }

    /// Where the crew actually is: the stop they're at or driving to,
    /// else the most recently completed one (by completedAt - list
    /// position says nothing about when it was done), else the last
    /// locked stop. nil when nothing is locked yet.
    static func crewPosition(_ locked: [Stop]) -> CLLocationCoordinate2D? {
        let placed = locked.filter { $0.coordinate != nil }
        let active = placed.last {
            $0.status == JobStatus.arrived.rawValue || $0.status == JobStatus.enRoute.rawValue
        }
        let latestDone = placed
            .filter { $0.completedAt != nil }
            .max { $0.completedAt! < $1.completedAt! }
        return (active ?? latestDone ?? placed.last)?.coordinate
    }

    /// The figure the Edit Route footer shows. Once any stop is done or
    /// under way, that's the driving still AHEAD - the same measure the
    /// Optimize preview uses. A whole-list total kept counting finished
    /// stops' legs, so applying a shorter order could make the footer
    /// number go UP (60.5 -> 68.6 km on a real route in the B1 test).
    static func drivingLeftKM(
        _ stops: [Stop],
        startCoordinate: CLLocationCoordinate2D? = nil,
        endCoordinate: CLLocationCoordinate2D? = nil
    ) -> (km: Double, isRemaining: Bool) {
        let locked = stops.filter(isLocked)
        guard !locked.isEmpty else {
            return (totalDistanceKM(stops, startCoordinate: startCoordinate, endCoordinate: endCoordinate), false)
        }
        let open = stops.filter { !isLocked($0) }
        let anchor = crewPosition(locked) ?? startCoordinate
        return (totalDistanceKM(open, startCoordinate: anchor, endCoordinate: endCoordinate), true)
    }

    static func plan(
        _ stops: [Stop],
        startCoordinate: CLLocationCoordinate2D? = nil,
        endCoordinate: CLLocationCoordinate2D? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Plan {
        let locked = stops.filter(isLocked)
        let open = stops.filter { !isLocked($0) }

        // Where the remaining work begins: the last locked stop the crew
        // has reached (or is heading to), else the route's own start.
        // With an anchor, every open stop is fair game; without one the
        // original first-stop-stays-first behavior is kept.
        let anchor = crewPosition(locked) ?? startCoordinate

        // Distances compare only the driving still AHEAD (anchor ->
        // open stops -> end). Finished stops are already driven, so
        // counting them made "Now" and "Optimized" apples and oranges.
        func remainingKM(_ order: [Stop]) -> Double {
            totalDistanceKM(order, startCoordinate: anchor, endCoordinate: endCoordinate)
        }
        // B8: time-windowed stops keep window order in every candidate.
        let rebuilt = applyWindowOrder(optimize(open, startCoordinate: anchor, endCoordinate: endCoordinate))
        let polished = applyWindowOrder(refine(open, startCoordinate: anchor, endCoordinate: endCoordinate))
        let best = remainingKM(polished) <= remainingKM(rebuilt) ? polished : rebuilt

        let beforeKM = remainingKM(open)
        let afterKM = remainingKM(best)
        // Never propose an order that isn't genuinely shorter (50 m is
        // below the noise of a straight-line estimate). In that case the
        // route is left exactly as it is - done stops included.
        let improves = afterKM < beforeKM - 0.05
        // B8: an order that breaks time-window order is worth fixing even
        // when the fix costs a little distance - a missed 8 AM window
        // matters more than a kilometre. Only when windows exist.
        let windowFix = applyWindowOrder(open).map(\.id) != open.map(\.id)
        let accept = improves || windowFix
        let proposed = accept ? locked + best : stops

        var plan = Plan(
            original: stops,
            proposed: proposed,
            beforeKM: beforeKM,
            afterKM: accept ? afterKM : beforeKM,
            lockedCount: locked.count,
            unplaceableCount: open.filter { $0.coordinate == nil }.count
        )
        plan.windowOrderFixed = windowFix && accept
        let aheadOrder = accept ? best : open
        plan.windowRisks = windowRisks(order: aheadOrder, startAt: now, from: anchor, timeZone: timeZone)
        return plan
    }

    // MARK: - B8 time windows

    /// Keeps stops that have a time window in window order (earliest
    /// window first) without moving anything else: the positions the
    /// windowed stops occupy stay theirs, only which windowed stop sits
    /// in each is re-sorted. The distance-optimized order is kept for
    /// every other stop.
    static func applyWindowOrder(_ stops: [Stop]) -> [Stop] {
        let slots = stops.indices.filter { stops[$0].hasTimeWindow }
        guard slots.count > 1 else { return stops }
        let sorted = slots.map { stops[$0] }.sorted {
            ($0.windowStartMinute!, $0.windowEndMinute!) < ($1.windowStartMinute!, $1.windowEndMinute!)
        }
        var out = stops
        for (slot, stop) in zip(slots, sorted) { out[slot] = stop }
        return out
    }

    /// Rough arrival estimate along `order`: straight-line distance x 1.3
    /// for roads, at `kmh`, plus `minutesPerStop` at each stop. Returns
    /// the windowed stops whose estimated arrival is after their window
    /// closes. An estimate, labelled as one wherever it's shown.
    static func windowRisks(order: [Stop], startAt: Date, from: CLLocationCoordinate2D?,
                            timeZone: TimeZone, kmh: Double = 30, minutesPerStop: Double = 8) -> [Stop] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let midnight = cal.startOfDay(for: startAt)
        var clock = startAt
        var here = from
        var late: [Stop] = []
        for stop in order {
            if let c = stop.coordinate {
                if let h = here { clock += distance(h, c) * 1.3 / (kmh * 1000 / 3600) }
                here = c
            }
            if let a = stop.windowStartMinute, let b = stop.windowEndMinute {
                let opens = midnight.addingTimeInterval(Double(a) * 60)
                let closes = midnight.addingTimeInterval(Double(b) * 60)
                if clock < opens { clock = opens }          // crew waits for it to open
                if clock > closes { late.append(stop) }
            }
            clock += minutesPerStop * 60
        }
        return late
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

    /// Great-circle distance in metres (haversine, mean Earth radius).
    ///
    /// NOT CLLocation.distance(from:): in the B1/B8 tests that returned
    /// slightly different values (up to ~0.5 m on a 125 km route) for the
    /// same two points depending on call history, which made "is this
    /// order shorter?" decisions flicker. Haversine is deterministic,
    /// fast, and well within the accuracy a straight-line estimate needs
    /// (< 0.5% from the ellipsoid at these distances).
    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let r = 6_371_008.8
        let rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad
        let dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
