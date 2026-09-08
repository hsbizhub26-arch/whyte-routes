import SwiftUI
import MapKit

/// Reports the rendered height of the bottom status card, so the map
/// can lift its locate/zoom controls above it rather than behind it.
private struct StatusCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DriverDashboardView: View {

    @ObservedObject var session = DriverSession.shared

    // See DriverTabView.embedded - when true this is hosted as the
    // owner's "My Route" tab, which has no Route-list/Profile tabs of
    // its own anymore, so this shows small header buttons to reach
    // them instead. A standalone driver (embedded == false) already
    // has real tabs for both, so these stay hidden there.
    var embedded: Bool = false

    @State private var isTogglingShift = false
    @State private var activeSheet: ActiveSheet?

    /// Measured height of the bottom status card, handed to the map so
    /// its locate/zoom controls float above the card instead of behind it.
    @State private var statusCardHeight: CGFloat = 0

    // ONE sheet modifier driven by an enum, rather than three chained
    // .sheet modifiers on the same view - stacking those silently drops
    // presentations in SwiftUI.
    private enum ActiveSheet: Identifiable {
        case stop(Stop)
        case route
        case profile

        /// The stop screen carries its own gold close button (see
        /// DriverStopView) because it can also be presented from the
        /// Route tab, which has no toolbar. Lets the dashboard skip
        /// stacking a second Close on top of it.
        var isStop: Bool {
            if case .stop = self { return true }
            return false
        }

        var id: String {
            switch self {
            case .stop(let s): return "stop-\(s.id)"
            case .route: return "route"
            case .profile: return "profile"
            }
        }
    }

    private var nextStop: Stop? { session.nextStop }
    private var completedCount: Int { session.activeStops.filter { $0.isCompleted }.count }
    private var totalStops: Int { session.activeStops.count }

    // MAP-FIRST, AND ACTUALLY MEANING IT.
    //
    // This used to be the map under a DraggableBottomSheet holding a
    // NavigationStack wrapped around a ScrollView of cards. Three
    // problems, all of which the driver felt at once:
    //
    //  1. STUTTER. The sheet's height was driven by @GestureState, so
    //     every single touch-move re-evaluated the sheet's entire
    //     content - NavigationStack, ScrollView and all the cards -
    //     while compositing a shadow over a live Map.
    //  2. A SECOND, SLOWER STUTTER. A 1Hz Timer.publish updated a
    //     @State date on THIS view to drive the shift clock, so the
    //     whole body, DriverMapView included, was invalidated once a
    //     second, forever, even with no shift running. The clock now
    //     lives in its own TimelineView subtree (see shiftLine) where
    //     ticking redraws a single line of text and nothing else.
    //  3. THE MAP WAS BARELY VISIBLE. 170pt collapsed, plus the tab
    //     bar, on a screen whose whole point is the map.
    //
    // So: no drag, no scroll, no nested navigation. A short fixed card
    // pinned to the bottom with the one thing that matters (the next
    // stop) and a small shift button. Everything longer-form already
    // has its own tab.
    var body: some View {
        ZStack(alignment: .bottom) {
            DriverMapView(bottomInset: statusCardHeight)
                .ignoresSafeArea(edges: .top)

            statusCard
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: StatusCardHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .onPreferenceChange(StatusCardHeightKey.self) { statusCardHeight = $0 }
        // EVERY ONE OF THESE WAS A DEAD END.
        //
        // All three are full-bleed ScrollViews with no navigation bar,
        // no Close button and no dismiss of their own. A sheet is
        // normally swipe-down dismissible, but the swipe lands on the
        // ScrollView and scrolls it instead - so a driver who opened
        // their route, a stop, or their profile could not get back out
        // of it. Force-quitting the app was the only exit.
        //
        // Wrapping the presentation (rather than editing each view)
        // fixes all three in one place and leaves DriverTabView, which
        // shows the same views as real tabs and must NOT gain a Close
        // button, completely untouched.
        //
        // The navigation bar also gives these screens a real safe-area
        // inset. DriverProfileView draws its own "Profile" title at the
        // very top, which was colliding with the status bar clock -
        // that title now sits below the bar instead of under it.
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                Group {
                    switch sheet {
                    case .stop(let stop): DriverStopView(stop: stop)
                    case .route: DriverRouteView()
                    case .profile: DriverProfileView()
                    }
                }
                .toolbar {
                    // Not for stop sheets - DriverStopView has its own
                    // gold close button (needed because the stop can
                    // also open from the Route tab, which has no
                    // toolbar), and two close controls stacked on top
                    // of each other read as a bug.
                    if !sheet.isStop {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                activeSheet = nil
                            } label: {
                                // Gloves, cold, 3am: a labelled control
                                // with a full-size hit area, not a small
                                // grey X in a corner.
                                Label("Close", systemImage: "chevron.down")
                                    .font(.body.weight(.semibold))
                            }
                            .tint(Color("WRThemeGold"))
                        }
                    }
                }
            }
            // The grabber, which is the "little tab for up and down"
            // and the reason these sheets can be pulled closed while
            // the content inside them still scrolls normally. iOS
            // routes a drag that starts on the grabber to the sheet
            // and a drag that starts anywhere else to the ScrollView,
            // so the two never compete - the same separation the
            // custom bottom sheet needed, except here the system
            // already implements it.
            //
            // Kept ALONGSIDE the Close button rather than instead of
            // it: a grabber is discoverable if you already know sheets,
            // and invisible if you don't, which is not a bet worth
            // making on someone wearing gloves at 3am.
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Status Card
    private var statusCard: some View {
        VStack(spacing: 10) {
            header

            routeState

            if session.assignedRoute != nil && totalStops > 0 {
                ProgressView(value: Double(completedCount), total: Double(max(1, totalStops)))
                    .tint(Color("WRThemeGold"))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color("WRThemeGold").opacity(0.25), lineWidth: 1)
        )
    }

    // Name, live shift clock, the small shift button, and (only when
    // embedded in the owner's tab) the two jump-off buttons.
    private var header: some View {
        HStack(spacing: 10) {
            if let driver = session.driver {
                Text(driver.name)
                    .font(.subheadline.bold())
                    .foregroundColor(Color("WRThemeGold"))
                    .lineLimit(1)
            }

            shiftLine

            Spacer(minLength: 4)

            if embedded {
                Button { activeSheet = .route } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundColor(Color("WRThemeGold"))
                }
                Button { activeSheet = .profile } label: {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(Color("WRThemeGold"))
                }
            }

            shiftButton
        }
    }

    // SMALL. A pill, not a full-width slab - the map is the screen.
    private var shiftButton: some View {
        Group {
            if let shift = session.activeShift, shift.isActive {
                Button {
                    isTogglingShift = true
                    Task {
                        await session.endShift()
                        isTogglingShift = false
                    }
                } label: {
                    Text(isTogglingShift ? "Ending…" : "End")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Color.red.opacity(0.85))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .disabled(isTogglingShift)
            } else {
                Button {
                    isTogglingShift = true
                    Task {
                        await session.startShift()
                        isTogglingShift = false
                    }
                } label: {
                    Text(isTogglingShift ? "Starting…" : "Start Shift")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Color("WRThemeGold"))
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                }
                .disabled(isTogglingShift)
            }
        }
    }

    /// The shift clock, isolated in its own TimelineView so that
    /// ticking once a second redraws THIS TEXT and nothing else. It
    /// used to be a Timer.publish feeding @State on the parent, which
    /// invalidated the whole screen - map included - every second.
    @ViewBuilder
    private var shiftLine: some View {
        if let shift = session.activeShift, shift.isActive {
            TimelineView(.periodic(from: shift.startedAt, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(shift.startedAt)))
                Text(String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - Route State
    // Deliberately at most three short lines. Anything longer belongs
    // on the Route tab, which exists.
    @ViewBuilder
    private var routeState: some View {
        if let stopsError = session.stopsError {
            // A route that couldn't be READ must never be reported as a
            // route that's FINISHED - a failed load leaves activeStops
            // empty, which is otherwise indistinguishable from done.
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Color("WRThemeGold"))
                Text(stopsError)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("Retry") { session.refresh() }
                    .font(.footnote.bold())
                    .foregroundColor(Color("WRThemeGold"))
            }
        } else if let stop = nextStop {
            Button {
                activeSheet = .stop(stop)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.customerName ?? "Customer")
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(stop.address)
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("\(completedCount)/\(totalStops)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.5))
                    Image(systemName: "chevron.right")
                        .font(.footnote.bold())
                        .foregroundColor(Color("WRThemeGold"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Navigation, one tap from the dashboard.
            //
            // The only way to start navigating used to be: tap the row
            // above, wait for the stop screen, find the button. That is
            // three deliberate actions for the thing a driver does at
            // every single stop, all day, in the cold - and the button
            // at the end of it was labelled "GO", which is why it took
            // this long for anyone to find it.
            //
            // Opens the stop screen rather than starting navigation
            // straight from here on purpose: navigating is not the only
            // thing that happens at a stop. The driver still needs the
            // gate code, the arrival and completion buttons, and the
            // customer's notes - so the stop screen is where they
            // belong, and this is a shortcut into it, not a bypass.
            Button {
                activeSheet = .stop(stop)
            } label: {
                Label("Start Navigation", systemImage: "location.north.circle.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color("WRThemeGold"))
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        } else if session.assignedRoute != nil && session.hasLoadedStops && totalStops > 0 {
            // Genuinely finished: the route had stops and every one is
            // done. Guarded on totalStops so an assigned route with no
            // stops yet never shows a celebration for work that never
            // existed.
            Text("Route complete 🎉")
                .font(.subheadline.bold())
                .foregroundColor(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if session.assignedRoute != nil && session.hasLoadedStops {
            // Route assigned, but it has no stops on it yet - the
            // dispatcher still has to add them. Not "complete."
            Text("No stops on this route yet")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if session.assignedRoute != nil {
            HStack(spacing: 8) {
                ProgressView().tint(Color("WRThemeGold"))
                Text("Loading your route…")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("No route assigned for today")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let shiftError = session.shiftError {
            Text(shiftError)
                .font(.caption)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
