import Foundation
import MapKit
import AVFoundation
import Combine

// In-app turn-by-turn for a single stop.
//
// MapKit gives us a route and its list of maneuvers (MKRoute.steps);
// it does NOT give a navigation engine. Everything that makes it feel
// like navigation - knowing which step you're on, deciding when to
// speak, noticing you've gone off-route - is here.
//
// Deliberately NOT a replacement for NavigationService's handoff to
// Waze/Google Maps, which still wins on live traffic and rerouting
// quality. This exists because bouncing out to another app mid-route
// costs more than it sounds like: the driver loses the stop screen,
// the property timer, and the arrival geofence until they remember to
// come back. Staying in-app keeps all of that running.
@MainActor
final class NavigationSession: NSObject, ObservableObject {

    @Published private(set) var route: MKRoute?
    @Published private(set) var isNavigating = false
    @Published private(set) var isRecalculating = false
    /// Text of the maneuver being driven toward ("Turn right onto Main St").
    @Published private(set) var currentInstruction: String?
    /// Metres to that maneuver, for the "in 300 m" line under it.
    @Published private(set) var distanceToManeuver: CLLocationDistance?
    @Published private(set) var remainingDistance: CLLocationDistance?
    @Published private(set) var remainingTime: TimeInterval?
    @Published private(set) var errorMessage: String?

    private var destination: CLLocationCoordinate2D?
    private var stepIndex = 0
    private var spokenThresholdsForStep: Set<Int> = []
    private var consecutiveOffRouteFixes = 0
    private var cancellables = Set<AnyCancellable>()

    private let synthesizer = AVSpeechSynthesizer()

    // Announce at a far, near, and immediate distance, the way a
    // driver actually needs it: once with time to change lanes, once
    // to commit, once at the turn itself.
    private static let announceThresholds: [CLLocationDistance] = [400, 150, 40]
    /// Treated as "this maneuver is done, move to the next one".
    private static let stepCompleteRadius: CLLocationDistance = 25
    /// How far off the line before we consider the driver to have left the route.
    private static let offRouteDistance: CLLocationDistance = 60
    /// Requires several consecutive bad fixes, so one GPS bounce in a
    /// parking garage doesn't trigger a pointless recalculation.
    private static let offRouteFixesBeforeReroute = 3

    // MARK: - Lifecycle

    func start(to destination: CLLocationCoordinate2D) {
        // Checked BEFORE flipping isNavigating, not inside
        // calculateRoute. Routing from an unknown origin can't work, so
        // starting first meant the button flipped to "End", no route
        // ever drew, and nothing said why - a dead button. The most
        // common cause is simply not being on shift: GPS tracking is
        // tied to the shift lifecycle, so say that rather than making
        // the driver guess.
        guard LocationService.shared.currentLocation != nil else {
            errorMessage = DriverSession.shared.activeShift == nil
                ? "Start your shift first - navigation needs GPS."
                : "Waiting for GPS…"
            return
        }

        self.destination = destination
        isNavigating = true
        errorMessage = nil
        configureAudioSession()
        observeLocation()
        Task { await calculateRoute(announceFirstStep: true) }
    }

    func stop() {
        isNavigating = false
        route = nil
        currentInstruction = nil
        distanceToManeuver = nil
        remainingDistance = nil
        remainingTime = nil
        stepIndex = 0
        spokenThresholdsForStep.removeAll()
        consecutiveOffRouteFixes = 0
        cancellables.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudioSession()
    }

    // MARK: - Routing

    private func calculateRoute(announceFirstStep: Bool) async {
        guard let destination,
              let origin = LocationService.shared.currentLocation else {
            errorMessage = "Waiting for GPS before starting navigation."
            return
        }

        isRecalculating = true
        defer { isRecalculating = false }

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile

        // The company's own avoid-tolls/highways preferences already
        // drive the external handoff (see NavigationService) - honour
        // the same settings here so in-app nav doesn't quietly route
        // differently from what an owner configured.
        let settings = CompanySession.shared.currentCompany?.navigationSettings ?? NavigationSettings()
        request.tollPreference = settings.avoidTolls ? .avoid : .any
        request.highwayPreference = settings.avoidHighways ? .avoid : .any

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let best = response.routes.first else {
                errorMessage = "No driving route to this stop."
                return
            }
            route = best
            stepIndex = 0
            spokenThresholdsForStep.removeAll()
            consecutiveOffRouteFixes = 0
            remainingDistance = best.distance
            remainingTime = best.expectedTravelTime
            currentInstruction = firstMeaningfulInstruction(in: best)
            if announceFirstStep, let currentInstruction {
                speak(currentInstruction)
            }
        } catch {
            errorMessage = "Couldn't get directions: \(error.localizedDescription)"
        }
    }

    // MKRoute's first step is almost always a bare "Proceed to <road>"
    // with no actual maneuver - skip to the first real turn so the
    // driver's first spoken instruction is useful.
    private func firstMeaningfulInstruction(in route: MKRoute) -> String? {
        route.steps.first(where: { !$0.instructions.isEmpty })?.instructions
    }

    // MARK: - Progress

    private func observeLocation() {
        LocationService.shared.$currentLocation
            .compactMap { $0 }
            .sink { [weak self] coordinate in
                Task { @MainActor in self?.updateProgress(at: coordinate) }
            }
            .store(in: &cancellables)
    }

    private func updateProgress(at coordinate: CLLocationCoordinate2D) {
        guard isNavigating, let route, stepIndex < route.steps.count else { return }

        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let step = route.steps[stepIndex]

        guard let maneuverPoint = step.polyline.coordinates.last else { return }
        let maneuverLocation = CLLocation(latitude: maneuverPoint.latitude, longitude: maneuverPoint.longitude)
        let distance = here.distance(from: maneuverLocation)
        distanceToManeuver = distance

        // Reached this maneuver - advance and announce the next one.
        if distance <= Self.stepCompleteRadius {
            advanceStep()
            return
        }

        announceIfCrossingThreshold(distance: distance, instruction: step.instructions)
        updateRemaining(from: here)
        checkOffRoute(from: here)
    }

    private func advanceStep() {
        guard let route else { return }
        stepIndex += 1
        spokenThresholdsForStep.removeAll()

        guard stepIndex < route.steps.count else {
            currentInstruction = "Arriving at your stop."
            speak("Arriving at your stop.")
            return
        }

        let next = route.steps[stepIndex]
        currentInstruction = next.instructions.isEmpty ? currentInstruction : next.instructions
        if !next.instructions.isEmpty {
            speak(next.instructions)
        }
    }

    // Speaks each threshold at most once per step, so a driver
    // crawling toward a light doesn't hear the same turn repeatedly.
    private func announceIfCrossingThreshold(distance: CLLocationDistance, instruction: String) {
        guard !instruction.isEmpty else { return }
        for (index, threshold) in Self.announceThresholds.enumerated() {
            if distance <= threshold, !spokenThresholdsForStep.contains(index) {
                spokenThresholdsForStep.insert(index)
                if threshold <= 40 {
                    speak(instruction)
                } else {
                    speak("In \(Int(distance)) metres, \(instruction)")
                }
                break
            }
        }
    }

    private func updateRemaining(from location: CLLocation) {
        guard let route, stepIndex < route.steps.count else { return }
        // Distance still to drive = what's left of the current step
        // plus every step after it. Cheaper and steadier than
        // re-measuring the whole polyline on every GPS fix.
        let remainingSteps = route.steps[stepIndex...].dropFirst()
        let afterThisStep = remainingSteps.reduce(0) { $0 + $1.distance }
        let toManeuver = distanceToManeuver ?? 0
        let total = afterThisStep + toManeuver
        remainingDistance = total
        // Scale the original ETA by how much distance is left rather
        // than re-requesting directions - a network call per GPS fix
        // would be wasteful and rate-limited.
        if route.distance > 0 {
            remainingTime = route.expectedTravelTime * (total / route.distance)
        }
    }

    private func checkOffRoute(from location: CLLocation) {
        guard let route else { return }
        let distanceFromLine = route.polyline.distance(from: location)
        if distanceFromLine > Self.offRouteDistance {
            consecutiveOffRouteFixes += 1
            if consecutiveOffRouteFixes >= Self.offRouteFixesBeforeReroute {
                consecutiveOffRouteFixes = 0
                speak("Rerouting.")
                Task { await calculateRoute(announceFirstStep: true) }
            }
        } else {
            consecutiveOffRouteFixes = 0
        }
    }

    // MARK: - Voice

    // Ducks music/podcasts rather than stopping them, and mixes with
    // other audio - a driver listening to something shouldn't have it
    // killed for the whole route just to hear four turns.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("⚠️ NavigationSession: audio session setup failed - \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-CA") ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}

// MARK: - Polyline helpers

extension MKPolyline {
    /// The polyline's points as coordinates.
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }

    /// Shortest distance from a location to this line - measured against
    /// each SEGMENT, not just the vertices. Vertex-only distance would
    /// report a driver as far off-route simply for being mid-way along
    /// one long straight stretch between two points.
    func distance(from location: CLLocation) -> CLLocationDistance {
        let coords = coordinates
        guard coords.count > 1 else {
            guard let only = coords.first else { return .greatestFiniteMagnitude }
            return location.distance(from: CLLocation(latitude: only.latitude, longitude: only.longitude))
        }

        var shortest = CLLocationDistance.greatestFiniteMagnitude
        for i in 0..<(coords.count - 1) {
            let d = location.distanceToSegment(start: coords[i], end: coords[i + 1])
            if d < shortest { shortest = d }
        }
        return shortest
    }
}

extension CLLocation {
    /// Perpendicular distance to a segment, projecting in flat map
    /// space (MKMapPoint). Fine at street scale - the error from
    /// ignoring curvature over a few hundred metres is far below the
    /// GPS accuracy we're comparing against anyway.
    func distanceToSegment(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) -> CLLocationDistance {
        let p = MKMapPoint(coordinate)
        let a = MKMapPoint(start)
        let b = MKMapPoint(end)

        let dx = b.x - a.x
        let dy = b.y - a.y
        if dx == 0 && dy == 0 {
            return p.distance(to: a)
        }

        // How far along the segment the closest point sits, clamped so
        // it can't fall past either end.
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
        let closest = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
        return p.distance(to: closest)
    }
}
