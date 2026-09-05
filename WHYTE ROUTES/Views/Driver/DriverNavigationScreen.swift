import SwiftUI
import MapKit
import Combine

/// Full-screen turn-by-turn, the way a driver actually uses it.
///
/// The stop screen shows navigation inside a 280pt card, which is fine
/// for glancing at a stop before you set off and wrong for the thing it
/// became: a person driving a truck at night reading a phone on a
/// mount. Every navigation app on the market goes full-bleed the moment
/// guidance starts, for the same reason - at speed you get one glance,
/// and the map has to fill it.
///
/// This is PRESENTATION ONLY. NavigationSession is not touched: it
/// already publishes the route, the current instruction, the distance
/// to the maneuver, what remains and whether it is rerouting, so this
/// screen just lays that state out at a size you can read while
/// moving. Nothing about the routing, the arrival geofence or the
/// voice changes - which is deliberate, days from submission.
struct DriverNavigationScreen: View {

    @ObservedObject var nav: NavigationSession
    let stopName: String
    let stopAddress: String
    let stopCoordinate: CLLocationCoordinate2D?
    let stopIndex: Int
    let stopCount: Int
    let isAtProperty: Bool
    let atPropertyElapsed: String?
    let onEnd: () -> Void
    let onComplete: () -> Void

    @ObservedObject private var location = LocationService.shared

    @State private var camera: MapCameraPosition =
        .userLocation(followsHeading: true, fallback: .automatic)
    /// False once the driver pans the map themselves, so the camera
    /// stops yanking itself back while they are looking ahead down the
    /// route. Re-armed by the recentre button.
    @State private var isFollowing = true

    var body: some View {
        ZStack(alignment: .top) {
            map
                .ignoresSafeArea()

            VStack(spacing: 0) {
                maneuverBanner
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer(minLength: 0)
                bottomBar
            }
        }
        // The screen a driver stares at while moving should not also be
        // the screen that dims and locks itself.
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Per-tick GPS while this screen is up - with the shift
            // tracker's 20m filter the camera lurched forward in 20m
            // jumps (and sat on the zoomed-out fallback until the first
            // qualifying fix), which read as "not following at all".
            LocationService.shared.setNavigationMode(true)
            updateCamera()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            LocationService.shared.setNavigationMode(false)
        }
        // Re-aim on every position fix, and again whenever the distance
        // to the next turn crosses into a tighter zoom band.
        .onChange(of: location.currentLocation?.latitude) { _, _ in updateCamera() }
        .onChange(of: location.currentHeading) { _, _ in updateCamera() }
        .onChange(of: nav.distanceToManeuver) { _, _ in updateCamera() }
        // Heartbeat: re-aim once a second regardless of which state
        // change did or didn't fire. This is what actually guarantees
        // "the camera follows the truck" - every event-driven trigger
        // above is an optimization on top of it.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            updateCamera()
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()

            if let stopCoordinate {
                Annotation("", coordinate: stopCoordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title)
                        .foregroundColor(Color("WRThemeGold"))
                        .background(Circle().fill(.white).padding(3))
                        .shadow(color: .black.opacity(0.35), radius: 4)
                }
            }

            if let polyline = nav.route?.polyline {
                // Thicker than the inline card's 6pt. On a full screen at
                // arm's length a 6pt line reads as a scratch.
                MapPolyline(polyline)
                    .stroke(Color("WRThemeGold"),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            }
        }
        .mapControlVisibility(.hidden)
        // Break follow-mode ONLY on a real finger gesture. The previous
        // approach watched the camera binding's positionedByUser flag,
        // but Map also writes back into the binding during programmatic
        // animated moves and can mark those as user-positioned - which
        // silently killed follow-mode on the very first camera set and
        // left the map parked on the zoomed-out whole-route framing.
        .simultaneousGesture(
            DragGesture(minimumDistance: 15).onChanged { _ in isFollowing = false }
        )
        .simultaneousGesture(
            MagnificationGesture().onChanged { _ in isFollowing = false }
        )
        .overlay(alignment: .bottomTrailing) { recentreButton }
        .overlay(alignment: .topTrailing) { compassBadge }
    }

    /// Google-style compass: the map is heading-up, so this shows where
    /// north went. The needle counter-rotates by the camera heading -
    /// red half pointing at true north on screen. Display-only.
    private var compassBadge: some View {
        ZStack {
            Circle().fill(.black.opacity(0.55))
            Image(systemName: "location.north.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.red)
                .rotationEffect(.degrees(-(location.currentHeading ?? 0)))
            Text("N")
                .font(.system(size: 7, weight: .heavy))
                .foregroundColor(.white)
                .offset(y: -14)
                .rotationEffect(.degrees(-(location.currentHeading ?? 0)))
        }
        .frame(width: 40, height: 40)
        .padding(.trailing, 14)
        // Below the maneuver banner, which owns the top of the screen.
        .padding(.top, 130)
        .allowsHitTesting(false)
    }

    /// Shown only once the driver has taken manual control of the map.
    @ViewBuilder
    private var recentreButton: some View {
        if !isFollowing {
            Button {
                isFollowing = true
                updateCamera()
            } label: {
                Image(systemName: "location.fill")
                    .font(.title3.bold())
                    .foregroundColor(.black)
                    .padding(14)
                    .background(Circle().fill(Color("WRThemeGold")))
                    .shadow(color: .black.opacity(0.4), radius: 5)
            }
            .padding(.trailing, 18)
            .padding(.bottom, 210)
        }
    }

    // MARK: - Driving camera
    //
    // A navigation camera is not a map camera. Three things separate the
    // two, and all three are what "like Waze" actually means:
    //
    //  HEADING-UP. The map rotates so the direction of travel is always
    //  up the screen. North-up forces the driver to do the rotation in
    //  their head at the exact moment they are deciding which way to
    //  turn.
    //
    //  PITCH. A flat overhead view wastes most of the screen on roads
    //  behind and beside you. Tilting to 60 degrees puts the road ahead
    //  across the whole display, which is the only part that matters.
    //
    //  ADAPTIVE ZOOM. Far from a turn you want context; approaching one
    //  you want to see which of two closely spaced streets is yours.
    //  A fixed zoom cannot do both, so the camera tightens as the
    //  maneuver approaches.

    private var cameraDistance: CLLocationDistance {
        guard let toManeuver = nav.distanceToManeuver else { return 700 }
        switch toManeuver {
        case ..<80:   return 190   // committing to the turn
        case ..<200:  return 300
        case ..<600:  return 480
        default:      return 700   // cruising between turns
        }
    }

    private func updateCamera() {
        guard isFollowing else { return }
        guard let coordinate = location.currentLocation else {
            // No fix yet (cold GPS, simulator without a location) - sit
            // over the destination at street level rather than leaving
            // the .automatic fallback framing the entire route.
            if let stopCoordinate {
                camera = .camera(MapCamera(centerCoordinate: stopCoordinate,
                                           distance: 700, heading: 0, pitch: 0))
            }
            return
        }
        let heading = location.currentHeading ?? 0

        // Sit the driver low in the frame rather than dead centre, so
        // the screen is mostly road AHEAD. Half the view is useless if
        // it is pointed at where they have already been.
        let lookAhead = pushed(coordinate, metres: cameraDistance * 0.28, bearing: heading)

        withAnimation(.easeInOut(duration: 0.45)) {
            camera = .camera(
                MapCamera(centerCoordinate: lookAhead,
                          distance: cameraDistance,
                          heading: heading,
                          pitch: 60)
            )
        }
    }

    /// Moves a coordinate `metres` along `bearing`. Flat-earth maths is
    /// fine at these distances - a few hundred metres of camera offset,
    /// not a route calculation.
    private func pushed(_ from: CLLocationCoordinate2D,
                        metres: CLLocationDistance,
                        bearing: CLLocationDirection) -> CLLocationCoordinate2D {
        let radians = bearing * .pi / 180
        let latitudeDelta = (metres * cos(radians)) / 111_320
        let longitudeDelta = (metres * sin(radians))
            / (111_320 * cos(from.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: from.latitude + latitudeDelta,
                                      longitude: from.longitude + longitudeDelta)
    }

    // MARK: - Maneuver banner

    private var maneuverBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            if !nav.isRecalculating {
                Image(systemName: DriverNavigationScreen.maneuverSymbol(nav.currentInstruction))
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 54)
            }

            VStack(alignment: .leading, spacing: 3) {
                if nav.isRecalculating {
                    Text("Rerouting…")
                        .font(.title2.bold())
                        .foregroundColor(.black)
                } else {
                    if let distance = nav.distanceToManeuver {
                        Text(DriverNavigationScreen.formattedDistance(distance))
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundColor(.black)
                    }
                    Text(nav.currentInstruction ?? "Starting navigation…")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.black)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = nav.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color("WRThemeGold"))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop \(stopIndex) of \(stopCount)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                    Text(stopName)
                        .font(.headline)
                        .foregroundColor(Color("WRThemeGold"))
                    Text(stopAddress)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
                if let remaining = nav.remainingDistance, let eta = nav.remainingTime {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(eta / 60)) min")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Text(DriverNavigationScreen.formattedDistance(remaining))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }

            if isAtProperty, let elapsed = atPropertyElapsed {
                Text("At property: \(elapsed)")
                    .font(.footnote.bold())
                    .foregroundColor(Color("WRThemeGold"))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
            }

            HStack(spacing: 10) {
                Button(action: onEnd) {
                    Label("End", systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(14)
                }

                Button(action: onComplete) {
                    Label("Mark Completed", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color("WRThemeGold"))
                        .cornerRadius(14)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.black.opacity(0.82))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Formatting
    // Static copies of the stop screen's helpers so this view does not
    // reach back into it. Kept identical on purpose: two different
    // roundings of the same distance on two screens reads as a bug.

    static func formattedDistance(_ metres: CLLocationDistance) -> String {
        metres < 1000
            ? "\(Int(metres.rounded())) m"
            : String(format: "%.1f km", metres / 1000)
    }

    static func maneuverSymbol(_ instruction: String?) -> String {
        guard let text = instruction?.lowercased() else { return "arrow.up" }
        if text.contains("left") && text.contains("slight") { return "arrow.turn.up.left" }
        if text.contains("right") && text.contains("slight") { return "arrow.turn.up.right" }
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        if text.contains("u-turn") { return "arrow.uturn.down" }
        if text.contains("merge") { return "arrow.merge" }
        if text.contains("exit") || text.contains("ramp") { return "arrow.up.right" }
        if text.contains("arrive") || text.contains("destination") { return "mappin.circle.fill" }
        return "arrow.up"
    }
}
