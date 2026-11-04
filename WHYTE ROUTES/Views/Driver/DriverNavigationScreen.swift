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
    /// nil once the stop is arrived or completed, which hides the
    /// fallback button rather than leaving a dead control on screen.
    let onArrive: (() -> Void)?

    /// How close the truck has to be before the manual "I've Arrived"
    /// fallback appears. Wider than the 40m geofence - that is the point
    /// of a fallback - but not the whole drive: arriving ends navigation,
    /// stamps the visit start and hands the customer's tracking pin over
    /// to the at-property state, none of which can be taken back, so a
    /// gloved thumb brushing it 3km out would strand the driver without
    /// directions and put the wrong time on the job.
    ///
    /// Two radii, latched: it appears inside 200m and only goes away past
    /// 300m, so GPS jitter at the edge can't flap it. Each flap resizes
    /// the card, which moves the map camera and the recentre chip.
    private static let arriveShowWithin: CLLocationDistance = 200
    private static let arriveHideBeyond: CLLocationDistance = 300

    /// Latched state for the fallback - see arriveShowWithin.
    @State private var arriveArmed = false

    private var showArriveFallback: Bool {
        onArrive != nil && arriveArmed
    }

    /// Straight-line distance from the truck to THIS stop's pin. Not
    /// nav.remainingDistance: that measures to the road point the route
    /// ends on, is nil with no route (no data in a storm), freezes once
    /// the last step completes, and after a late reroute can even belong
    /// to the previous stop's route.
    private func updateArriveArmed(_ here: CLLocationCoordinate2D?) {
        guard let here, let stopCoordinate else { return }
        let distance = CLLocation(latitude: here.latitude, longitude: here.longitude)
            .distance(from: CLLocation(latitude: stopCoordinate.latitude, longitude: stopCoordinate.longitude))
        if !arriveArmed, distance <= Self.arriveShowWithin {
            arriveArmed = true
        } else if arriveArmed, distance > Self.arriveHideBeyond {
            arriveArmed = false
        }
    }

    /// Top edge of the bottom card in global coordinates, measured, so the
    /// map's recentre chip can sit just above it at any card height.
    @State private var bottomCardTopY: CGFloat = 0
    let onEnd: () -> Void
    let onComplete: () -> Void

    /// Measured height of the floating bottom card.
    @State private var bottomCardHeight: CGFloat = 0

    /// The strip of map the bottom card sits on top of. Handed to the
    /// map as a camera inset so MapKit frames the truck inside what the
    /// driver can actually SEE, instead of the middle of the glass -
    /// which put the puck and the road immediately ahead of it directly
    /// behind this card. Zero unless actually navigating, so the
    /// viewport returns to full frame the moment the drive ends.
    private var navigationBottomInset: CGFloat {
        nav.isNavigating ? bottomCardHeight : 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The map, its camera and the follow loop live in their own
            // view (NavMapCanvas, below). THAT is the lag fix: the
            // camera animating and the map redrawing every second no
            // longer drag the maneuver banner and bottom bar through a
            // re-layout too, and - because NavMapCanvas is Equatable -
            // the map only rebuilds when the route line or the zoom band
            // actually change, not every time the ETA text ticks.
            NavMapCanvas(
                nav: nav,
                stopCoordinate: stopCoordinate,
                routePolyline: nav.route?.polyline,
                zoomDistance: Self.zoomDistance(for: nav.distanceToManeuver),
                bottomInset: navigationBottomInset,
                cardTopGlobalY: bottomCardTopY
            )
            .equatable()
            .ignoresSafeArea()

            VStack(spacing: 0) {
                maneuverBanner
                    .padMaxWidth(600)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer(minLength: 0)
                // Capped BEFORE the measuring background, so the camera
                // inset and recentre chip measure the card as drawn.
                bottomBar
                    .padMaxWidth(600)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: BottomCardHeightKey.self,
                                    value: proxy.size.height
                                )
                                .preference(
                                    key: BottomCardTopKey.self,
                                    value: proxy.frame(in: .global).minY
                                )
                        }
                    )
            }
            .onPreferenceChange(BottomCardHeightKey.self) { height in
                bottomCardHeight = height
            }
            .onPreferenceChange(BottomCardTopKey.self) { top in
                bottomCardTopY = top
            }
        }
        // The screen a driver stares at while moving should not also be
        // the screen that dims and locks itself.
        .persistentSystemOverlays(.hidden)
        // Runs on every GPS fix WITHOUT observing location: the closure
        // only writes arriveArmed when it actually flips, so the card
        // re-renders at the threshold, not once a second.
        .onReceive(LocationService.shared.$currentLocation) { here in
            updateArriveArmed(here)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: - Adaptive zoom bands
    //
    // Computed here, and passed to the map as a single already-bucketed
    // distance, so the map's Equatable check only trips four times a
    // turn (the band transitions) instead of on every metre the raw
    // distance-to-maneuver changes. Far from a turn you want context;
    // approaching one you want to see which of two closely spaced
    // streets is yours - a fixed zoom can't do both.
    //
    // The bands are aligned to the voice callouts (400m / 150m / 40m,
    // see NavigationSession.announceThresholds) so the map tightens
    // WITH each announcement. Previously the only obvious step came
    // under 80m - the driver heard "turn right" three times before the
    // map visibly zoomed. Now the first callout at 400m already brings
    // the camera in, and each later one pulls it tighter.
    //
    // Far more aggressive than the first pass. 180m at the turn read as
    // "not zooming in" on a real drive: with the 60-degree tilt that is
    // still a wide view. Google/Waze get down to near street level at
    // the maneuver, so the tightest band is now 90m - a 5.5x pull-in
    // from cruising that a driver cannot miss.
    //
    // Finer steps than the previous four so the pull-in reads as a
    // continuous zoom rather than a couple of jumps, and tighter at the
    // end (70m - genuinely street level). Eight bands is still only a
    // handful of Equatable transitions per turn.
    static func zoomDistance(for toManeuver: CLLocationDistance?) -> CLLocationDistance {
        guard let toManeuver else { return 500 }
        switch toManeuver {
        case ..<60:   return 70    // final "turn left" (voice at 40m) - street level
        case ..<100:  return 100
        case ..<160:  return 140   // second callout (voice at 150m)
        case ..<300:  return 200
        case ..<420:  return 260   // FIRST callout (voice at 400m) - clearly closer
        case ..<600:  return 340
        case ..<900:  return 420
        default:      return 500   // cruising between turns
        }
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

            // Fallback for when the 40m geofence does not trip - a GPS
            // fix drifting wide, or a yard entrance set back from the
            // pin. Without it the only way to arrive was to back out of
            // navigation to the stop screen first. Only offered near the
            // stop (see arriveFallbackRadius), and outlined rather than
            // solid gold so it never reads as the Mark Completed button
            // directly beneath it.
            if showArriveFallback, let onArrive {
                Button(action: onArrive) {
                    Label("I've Arrived", systemImage: "mappin.circle.fill")
                        .font(.headline)
                        .foregroundColor(Color("WRThemeGold"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color("WRThemeGold"), lineWidth: 2)
                        )
                }
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
        // Clearance ABOVE the bottom safe-area inset the VStack is
        // already laid out inside. 8pt put the card hard against the
        // home indicator - and on a device whose bottom inset is 0 it
        // sat almost on the physical edge, which is what read as the
        // card being cut off.
        .padding(.bottom, 24)
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

// MARK: - Isolated map surface
//
// Everything that redraws while driving - the MapKit view, the follow
// camera, the 1 Hz camera loop, the compass and the recentre control -
// lives here, apart from the maneuver banner and bottom bar. Two things
// make navigation smooth:
//
//  1. It's Equatable, so when the PARENT re-renders (ETA/instruction
//     ticking every second) this whole map subtree is skipped unless
//     the route line, the destination pin or the zoom band changed.
//
//  2. It owns the camera state, so the camera animating no longer
//     re-lays-out the banner and bars - and their text ticking no
//     longer re-declares the map.
//
// A navigation camera is not a map camera: it's HEADING-UP (rotates so
// travel is up-screen) and PITCHED (tilted 60 so the screen is mostly
// road ahead) - which is what "like Waze" actually means.
private struct NavMapCanvas: View, Equatable {

    /// Only for the voice mute button, which observes it itself - so it
    /// is deliberately left out of == below (same object for the drive).
    let nav: NavigationSession
    let stopCoordinate: CLLocationCoordinate2D?
    let routePolyline: MKPolyline?
    let zoomDistance: CLLocationDistance
    /// Height of the bottom card, as a camera inset.
    let bottomInset: CGFloat
    /// Global Y of the bottom card's top edge, for the recentre chip.
    let cardTopGlobalY: CGFloat

    // Skip re-rendering unless something the MAP actually draws changed.
    // Deliberately does NOT look at location/heading - those drive the
    // camera through @ObservedObject inside, not the parent's diffing.
    static func == (a: NavMapCanvas, b: NavMapCanvas) -> Bool {
        // bottomInset MUST be compared. It arrives as 0 and is replaced
        // by the measured height on the first layout pass; without it
        // here, Equatable would swallow that update and the camera would
        // stay centred on the glass for the whole drive.
        a.bottomInset == b.bottomInset
            && a.cardTopGlobalY == b.cardTopGlobalY
            && a.zoomDistance == b.zoomDistance
            && a.routePolyline === b.routePolyline
            && a.stopCoordinate?.latitude == b.stopCoordinate?.latitude
            && a.stopCoordinate?.longitude == b.stopCoordinate?.longitude
    }

    @ObservedObject private var location = LocationService.shared

    @State private var camera: MapCameraPosition =
        .userLocation(followsHeading: true, fallback: .automatic)
    /// False once the driver pans the map themselves, so the camera
    /// stops yanking itself back while they look ahead down the route.
    /// Re-armed by the recentre button.
    @State private var isFollowing = true
    /// Global Y of this map's bottom edge. See recentreClearance.
    @State private var mapBottomY: CGFloat = 0
    /// The map's current rotation, so the car can point the right way
    /// when the driver has panned off the heading-up camera.
    @State private var mapHeading: CLLocationDirection = 0

    /// When this map appeared. Follow-mode is immune to gestures for a
    /// moment after it does: the tap that started navigation lands on
    /// this very map as it slides in, and its tail registered as a
    /// "drag" that killed follow-mode the instant nav began - so the
    /// camera never tracked the truck until the driver hit recentre.
    @State private var appearedAt = Date()

    /// A pan must be this deliberate to break follow-mode. 15pt let a
    /// brushed finger in a moving truck do it; 40pt is an intentional
    /// swipe.
    private static let deliberatePanDistance: CGFloat = 40
    private static let gestureGracePeriod: TimeInterval = 2.0

    private func userTookOverMap() {
        guard Date().timeIntervalSince(appearedAt) > Self.gestureGracePeriod else { return }
        isFollowing = false
    }

    /// 1 Hz - matched to the GPS fix rate. Re-animating faster than new
    /// positions arrive just re-tweens to the same spot and burns
    /// frames, which is a large part of what read as "laggy."
    private let cameraTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Map(position: $camera) {
            // Route first so the car draws on top of it. Only the part
            // still ahead of the car - see RouteAhead.
            if let routePolyline {
                let ahead = location.currentLocation.map { RouteAhead.coordinates(of: routePolyline, from: $0) }
                if let ahead, ahead.count > 1 {
                    MapPolyline(coordinates: ahead)
                        .stroke(Color("WRThemeGold"),
                                style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                } else {
                    MapPolyline(routePolyline)
                        .stroke(Color("WRThemeGold"),
                                style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                }
            }

            // The car, not the system blue dot. The camera is heading-up,
            // so the car's on-screen angle is travel heading minus the
            // map's heading - straight up while following.
            if let here = location.currentLocation {
                Annotation("", coordinate: here, anchor: .center) {
                    CarMarker(rotation: (location.currentHeading ?? mapHeading) - mapHeading, size: 38)
                }
            } else {
                UserAnnotation()
            }

            if let stopCoordinate {
                Annotation("", coordinate: stopCoordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title)
                        .foregroundColor(Color("WRThemeGold"))
                        .background(Circle().fill(.white).padding(3))
                        .shadow(color: .black.opacity(0.35), radius: 4)
                }
            }
        }
        .onMapCameraChange(frequency: .continuous) { context in
            mapHeading = context.camera.heading
        }
        .mapControlVisibility(.hidden)
        // Camera inset for the bottom card. MapKit places an explicit
        // MapCamera centreCoordinate at the centre of the INSET
        // viewport, so this lifts the whole frame off the card and puts
        // the truck in the lower third of the visible map with the road
        // ahead in view. Measured in the simulator: with this inset the
        // existing 0.28 look-ahead lands the puck at 633pt inside a
        // 0-751pt visible region, 118pt clear of the card - and it is
        // scale-invariant, identical at every zoom band.
        //
        // The .ignoresSafeArea() below is deliberate and load-bearing:
        // it re-zeroes the safe area for the gestures and overlays that
        // follow WITHOUT undoing the camera shift.
        .safeAreaPadding(.bottom, bottomInset)
        .ignoresSafeArea()
        // Break follow-mode only on a real finger gesture.
        .simultaneousGesture(
            DragGesture(minimumDistance: Self.deliberatePanDistance).onChanged { _ in userTookOverMap() }
        )
        .simultaneousGesture(
            MagnificationGesture().onChanged { _ in userTookOverMap() }
        )
        // Measures where this full-bleed map ends on screen. A background,
        // not an overlay: a full-size layer on top of the map could claim
        // the pans and pinches meant for it.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MapBottomKey.self, value: proxy.frame(in: .global).maxY)
            }
        )
        .onPreferenceChange(MapBottomKey.self) { bottom in
            mapBottomY = bottom
        }
        .overlay(alignment: .bottomTrailing) {
            recentreButton
                .padding(.bottom, recentreClearance)
        }
        .overlay(alignment: .topTrailing) { compassBadge }
        // Directly under the compass (210pt + 40pt badge + 12pt gap).
        .overlay(alignment: .topTrailing) {
            VoiceMuteButton(nav: nav)
                .padding(.trailing, 14)
                .padding(.top, 262)
        }
        .onAppear {
            appearedAt = Date()
            LocationService.shared.setNavigationMode(true)
            updateCamera()
        }
        .onDisappear { LocationService.shared.setNavigationMode(false) }
        .onReceive(cameraTick) { _ in
            // Before updateCamera, not inside it: that returns early
            // while the driver has panned away, and the compass badge
            // still needs the right orientation then.
            LocationService.shared.syncHeadingOrientation()
            updateCamera()
        }
    }

    /// Google-style compass: the map is heading-up, so this shows where
    /// north went. Display-only.
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
        // Clears the maneuver banner even when the instruction wraps to
        // two lines. At 130 the badge sat UNDER the banner - the needle
        // and "N" poked out of its bottom-right corner and nothing else
        // was visible. Banner math: ~59pt safe area + 8pt top padding +
        // up to ~130pt of banner = ~197pt, so 210 clears it with margin.
        .padding(.top, 210)
        .allowsHitTesting(false)
    }

    /// Always on screen, like Google's locate-me chip.
    private var recentreButton: some View {
        Button {
            isFollowing = true
            updateCamera()
        } label: {
            Image(systemName: isFollowing ? "location.fill" : "location.fill.viewfinder")
                .font(.title3.bold())
                .foregroundColor(isFollowing ? Color("WRThemeGold") : .black)
                .padding(isFollowing ? 11 : 14)
                .background(Circle().fill(isFollowing ? Color.black.opacity(0.55) : Color("WRThemeGold")))
                .shadow(color: .black.opacity(0.4), radius: 5)
        }
        .padding(.trailing, 18)
    }

    /// Distance of the recentre chip above the bottom of the map: 12pt
    /// clear of the bottom card, whatever height the card is. It used to
    /// be a fixed 210, which left 2pt at the card's shortest - so a
    /// wrapped stop name, larger text, or the arrive button pushed the
    /// card over the chip, the same locate-button-behind-the-drawer bug
    /// already fixed on the other maps. 210 remains the floor and the
    /// value for the first frame, before the card has been measured.
    ///
    /// Both edges are global coordinates, so this holds whatever the safe
    /// area: the map ignores it, the card respects it.
    private var recentreClearance: CGFloat {
        guard cardTopGlobalY > 0, mapBottomY > 0 else { return 210 }
        return max(210, mapBottomY - cardTopGlobalY + 12)
    }

    private func updateCamera() {
        guard isFollowing else { return }
        guard let coordinate = location.currentLocation else {
            // No fix yet (cold GPS, simulator without a location) - sit
            // over the destination rather than framing the whole route.
            if let stopCoordinate {
                camera = .camera(MapCamera(centerCoordinate: stopCoordinate,
                                           distance: 700, heading: 0, pitch: 0))
            }
            return
        }
        let heading = location.currentHeading ?? 0

        // Sit the driver low in the frame so the screen is mostly road
        // AHEAD, not where they've already been.
        let lookAhead = pushed(coordinate, metres: zoomDistance * 0.28, bearing: heading)

        // Linear over one tick interval so the camera is always
        // mid-glide toward the next target when the next tick arrives -
        // continuous motion, not eased hops that start and stop.
        withAnimation(.linear(duration: 1)) {
            camera = .camera(
                MapCamera(centerCoordinate: lookAhead,
                          distance: zoomDistance,
                          heading: heading,
                          pitch: 60)
            )
        }
    }

    /// Moves a coordinate `metres` along `bearing`. Flat-earth maths is
    /// fine at a few hundred metres of camera offset.
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
}

/// Reports the real rendered height of the bottom card, so the map
/// can inset its camera by exactly what the card covers rather than a
/// number guessed per device.
/// Global Y of the navigation map's bottom edge. See recentreClearance.
// MARK: - Car marker (shared by every map that shows a truck)
//
// A top-down car, front at the top, rotated to the direction of travel -
// the Waze/Google Maps look. Replaces the system blue dot on the driver's
// maps and the plain coloured dot on the owner's fleet map, which sat in
// the SAME colour as the route line under it and read as a smudge.
// Default: blue body, white windows - deliberately not gold, so it never
// blends into the gold route lines.
struct CarMarker: View {
    /// Degrees clockwise, relative to the screen (heading minus map heading).
    var rotation: Double = 0
    var color: Color = Color(red: 0.10, green: 0.45, blue: 0.95)
    var windows: Color = .white
    var outline: Color = .white
    var size: CGFloat = 34

    var body: some View {
        let w = size * 0.56, h = size
        return ZStack {
            RoundedRectangle(cornerRadius: w * 0.38)
                .fill(color)
                .frame(width: w, height: h)
                .overlay(RoundedRectangle(cornerRadius: w * 0.38).stroke(outline, lineWidth: 2.5))
            // Windshield: the front, so the top of the car.
            RoundedRectangle(cornerRadius: 3)
                .fill(windows.opacity(0.9))
                .frame(width: w * 0.68, height: h * 0.2)
                .offset(y: -h * 0.17)
            // Rear window.
            RoundedRectangle(cornerRadius: 2)
                .fill(windows.opacity(0.6))
                .frame(width: w * 0.6, height: h * 0.12)
                .offset(y: h * 0.27)
        }
        .rotationEffect(.degrees(rotation))
        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
        .frame(width: size + 8, height: size + 8)
    }
}

// MARK: - Voice mute (Google Maps style speaker button)
//
// Observes the session itself, so it updates on tap even though the
// map canvas around it only re-renders when the route or zoom change.
private struct VoiceMuteButton: View {
    @ObservedObject var nav: NavigationSession

    var body: some View {
        Button {
            nav.toggleVoice()
        } label: {
            Image(systemName: nav.voiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(nav.voiceMuted ? Color.black : Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(nav.voiceMuted ? Color("WRThemeGold") : Color.black.opacity(0.55)))
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .accessibilityLabel(nav.voiceMuted ? "Unmute voice directions" : "Mute voice directions")
    }
}

// MARK: - Route ahead only
//
// The navigation line used to be the whole route from where the drive
// started, so everything already driven stayed painted behind the car.
// This keeps only what's ahead: from the point on the route nearest the
// car, onward. Planar maths in MKMapPoint space - exact enough at street
// scale, and cheap enough to run on every fix.
enum RouteAhead {
    static func coordinates(of polyline: MKPolyline, from here: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        guard count > 1 else { return [] }
        let pts = polyline.points()
        let p = MKMapPoint(here)
        var bestIndex = 0
        var bestPoint = pts[0]
        var bestDist = Double.greatestFiniteMagnitude
        for i in 0..<(count - 1) {
            let a = pts[i], b = pts[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
            t = max(0, min(1, t))
            let proj = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = (proj.x - p.x) * (proj.x - p.x) + (proj.y - p.y) * (proj.y - p.y)
            if d < bestDist { bestDist = d; bestIndex = i; bestPoint = proj }
        }
        var out = [bestPoint.coordinate]
        for i in (bestIndex + 1)..<count { out.append(pts[i].coordinate) }
        return out
    }
}

private struct MapBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Global Y of the bottom card's top edge. See recentreClearance.
private struct BottomCardTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BottomCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
