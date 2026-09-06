import SwiftUI

struct OwnerDashboardView: View {

    @ObservedObject private var companySession = CompanySession.shared
    @ObservedObject private var access = FeatureAccessManager.shared
    @StateObject private var driverVM = DriverViewModel()
    @StateObject private var routeService = RouteService.shared
    @State private var showReports = false
    @State private var customerCount = 0
    @State private var showUpgradePrompt = false
    /// Closed by default. The map is the screen; the panel is something
    /// you ask for.
    @State private var isPanelOpen = false

    private var totalCompletedStops: Int {
        driverVM.drivers.reduce(0) { $0 + routeService.reportFor($1).completedStops }
    }

    private var totalStopsToday: Int {
        routeService.routes.reduce(0) { $0 + $1.stops.count }
    }

    /// Drivers that currently have a route to run - the "actually out
    /// working" number, distinct from total headcount.
    private var driversOnRoute: Int {
        driverVM.drivers.filter { ($0.activeRoute ?? "").isEmpty == false }.count
    }

    private var completionFraction: Double {
        guard totalStopsToday > 0 else { return 0 }
        return min(1, Double(totalCompletedStops) / Double(totalStopsToday))
    }

    var body: some View {
        // NO DRAG. A tab you tap.
        //
        // The draggable sheet was hard to move and permanently in the
        // way: 150pt of panel sitting over the map whether or not
        // anyone wanted it, and a drag that competed with the list
        // scrolling inside it. Dragging is also the wrong gesture for
        // something used one-handed - it demands a sustained, accurate
        // movement to do what a single tap can.
        //
        // So the panel is closed by default and opens on a tap. The tab
        // sits bottom-LEFT, directly above the tab bar, where a thumb
        // already is and where it cannot collide with the map controls
        // on the right.
        ZStack(alignment: .bottom) {
            LiveFleetMapView(driverVM: driverVM)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                HStack {
                    panelTab
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)

                if isPanelOpen {
                    widgetSheet
                        .frame(maxHeight: 380)
                        // CLIPPED, then backgrounded. Without the clip
                        // the ScrollView's content drew straight past
                        // the rounded corners of its own panel, so the
                        // card at the bottom appeared to spill out and
                        // then vanish under the tab bar - which read as
                        // "it won't scroll" when it was scrolling into
                        // a region nothing could see or touch.
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.black)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 12, y: -4)
                        .padding(.horizontal, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 6)
            // The map underneath deliberately bleeds past the bottom
            // safe area; this overlay must not. Without it the panel
            // ran under the tab bar and lost its last 80-odd points to
            // something the finger can't reach.
            .safeAreaPadding(.bottom)
        }
        .onAppear {
            driverVM.startLiveUpdates()
            routeService.loadRoutesOnce()
            CustomerRepository().fetchCustomers { result in
                if case .success(let list) = result {
                    customerCount = list.count
                }
            }
        }
        .sheet(isPresented: $showReports) {
            DriverReportsView()
        }
        .sheet(isPresented: $showUpgradePrompt) {
            UpgradeRequiredView(
                featureName: "More Customers",
                requiredTier: SubscriptionTier(rawValue: access.tier.rawValue + 1) ?? .enterprise
            )
        }
    }

    /// Small, labelled, and it says which way it will go. A bare
    /// chevron makes someone guess what it does; "Dashboard" with an
    /// arrow does not.
    private var panelTab: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                isPanelOpen.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isPanelOpen ? "chevron.down" : "chevron.up")
                    .font(.caption.bold())
                Text("Dashboard")
                    .font(.subheadline.bold())
            }
            .foregroundColor(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color("WRThemeGold"))
            .clipShape(Capsule())
            .shadow(radius: 6)
        }
        .buttonStyle(.plain)
    }

    var widgetSheet: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                HStack(spacing: 14) {
                    statCard(
                        icon: "person.2.fill",
                        tint: WRTheme.gold,
                        value: "\(driverVM.drivers.count)",
                        title: "Drivers"
                    )
                    statCard(
                        icon: "point.topleft.down.curvedto.point.bottomright.up.fill",
                        tint: WRTheme.routeTeal,
                        value: "\(routeService.routes.count)",
                        title: "Active Routes"
                    )
                }
                .padding(.horizontal)

                HStack(spacing: 14) {
                    statCard(
                        icon: "mappin.and.ellipse",
                        tint: WRTheme.gold,
                        value: "\(totalCompletedStops)/\(totalStopsToday)",
                        title: "Stops Done"
                    )
                    statCard(
                        icon: "checkmark.circle.fill",
                        tint: WRTheme.routeTeal,
                        value: "\(Int((completionFraction * 100).rounded()))%",
                        title: "Completion"
                    )
                }
                .padding(.horizontal)

                HStack(spacing: 14) {
                    statCard(
                        icon: "person.crop.circle.fill",
                        tint: WRTheme.gold,
                        value: "\(customerCount)",
                        title: "Customers"
                    )
                    statCard(
                        icon: "figure.walk.motion",
                        tint: WRTheme.routeTeal,
                        value: "\(driversOnRoute)",
                        title: "On Route"
                    )
                }
                .padding(.horizontal)

                driverReportsWidget

                if let limit = access.customerLimit {
                    customerUsageWidget(limit: limit)
                }

                Spacer(minLength: 16)
            }
            .padding(.top, 4)
        }
    }
}

extension OwnerDashboardView {

    // Customers/Assign/Fleet/Reports used to be repeated here as
    // buttons AND as tabs below - identical destinations shown twice.
    // Removed the buttons; the tab bar is the one place to navigate
    // from now, this screen is just the at-a-glance overview.
    var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .foregroundColor(.white.opacity(0.6))
                    .font(.subheadline)
                Text(companySession.currentCompany?.name ?? "your team")
                    .foregroundColor(WRTheme.gold)
                    .font(.title.bold())
            }
            Spacer()

            Image(systemName: "map.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(WRTheme.gold.gradient)
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    // Real summary data (completedStops is now correctly computed -
    // see RouteService.reportFor/stopsByRoute), not just a bare
    // shortcut - tapping it drills into the full Reports screen for
    // detail, same "summary card -> detail" pattern as any dashboard
    // widget, not a duplicate of the tab bar.
    var driverReportsWidget: some View {
        Button {
            showReports = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(WRTheme.gold.opacity(0.2), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: completionFraction)
                        .stroke(WRTheme.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "doc.text.fill")
                        .font(.callout)
                        .foregroundColor(WRTheme.gold)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Driver Reports")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("\(totalCompletedStops) stop\(totalCompletedStops == 1 ? "" : "s") completed")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding()
            .background(WRTheme.softBlack)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(WRTheme.gold.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .padding(.horizontal)
    }

    // Shown only for tiers with an actual cap (FeatureAccessManager
    // returns nil for unlimited tiers) - a free/trial owner sees at a
    // glance how much runway they have left without digging into the
    // Customers tab, and can tap straight through to upgrade once
    // they're close to the limit.
    func customerUsageWidget(limit: Int) -> some View {
        let fraction = limit > 0 ? min(1, Double(customerCount) / Double(limit)) : 0
        let isNearLimit = customerCount >= limit

        return Button {
            if isNearLimit { showUpgradePrompt = true }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Image(systemName: "house.fill")
                        .font(.title3)
                        .foregroundColor(WRTheme.gold)
                        .frame(width: 46, height: 46)
                        .background(WRTheme.gold.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Customers & Addresses")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("\(customerCount) of \(limit) used (\(access.tier.displayName) plan)")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Spacer()

                    if isNearLimit {
                        Image(systemName: "lock.fill")
                            .foregroundColor(WRTheme.gold)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(WRTheme.gold.opacity(0.15))
                        Capsule()
                            .fill(isNearLimit ? Color.red : WRTheme.gold)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
            .padding()
            .background(WRTheme.softBlack)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(WRTheme.gold.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .padding(.horizontal)
    }

    func statCard(icon: String, tint: Color, value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(value)
                .foregroundColor(.white)
                .font(.system(size: 30, weight: .bold))
            Text(title)
                .foregroundColor(.white.opacity(0.6))
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(WRTheme.softBlack)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }
}
