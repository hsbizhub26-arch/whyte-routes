import SwiftUI
import MapKit
import Combine

struct DriverDashboardView: View {

    @ObservedObject var session = DriverSession.shared
    @ObservedObject var nextController = DriverNextStopController.shared

    // See DriverTabView.embedded - when true this is hosted as the
    // owner's "My Route" tab, which has no Route-list/Profile tabs of
    // its own anymore, so this shows small header buttons to reach
    // them instead. A standalone driver (embedded == false) already
    // has real tabs for both, so these stay hidden there.
    var embedded: Bool = false

    @State private var now = Date()
    @State private var isTogglingShift = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var elapsedShiftText: String {
        guard let startedAt = session.activeShift?.startedAt else { return "0:00:00" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    var nextStop: Stop? {
        nextController.nextStop
    }

    var completedCount: Int {
        session.activeStops.filter { $0.isCompleted }.count
    }

    var totalStops: Int {
        session.activeStops.count
    }

    var progressText: String {
        "\(completedCount) / \(totalStops) stops completed"
    }

    // Map-first, same pattern as OwnerDashboardView: the live map is
    // the primary content, everything the driver actually needs to
    // act on (shift control, route progress, next stop) lives in a
    // draggable bottom sheet on top of it - map stays visible and
    // interactive underneath at every sheet detent.
    var body: some View {
        ZStack {
            DriverMapView()
            DraggableBottomSheet(collapsedHeight: 170) {
                widgetSheet
            }
        }
        .onAppear {
            nextController.updateNextStop()
        }
        .onReceive(clock) { now = $0 }
    }

    // Job-focused, Uber-Driver-style priority: the one thing a driver
    // actually needs right now (their next stop, one big action
    // button) leads, visible at the sheet's collapsed height without
    // dragging. A name/greeting and the full shift-timer readout used
    // to occupy that entire collapsed space instead - true but not
    // actionable, so it's compact header info now, not the headline.
    private var widgetSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    compactHeader

                    // MARK: - Next Stop (the primary, above-the-fold content)
                    if let stop = nextStop {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Next Stop")
                                    .font(.headline)
                                    .foregroundColor(Color("WRThemeGold"))
                                Spacer()
                                Text("Stop \(stop.order + 1) of \(totalStops)")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.6))
                            }

                            Text(stop.customerName ?? "Customer")
                                .font(.title2.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(stop.address)
                                .foregroundColor(.white.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            NavigationLink {
                                DriverStopView(stop: stop)
                            } label: {
                                Text("Open Stop")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color("WRThemeGold"))
                                    .foregroundColor(.black)
                                    .cornerRadius(14)
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.25))
                        .cornerRadius(16)
                        .padding(.horizontal)
                    } else if session.assignedRoute != nil {
                        VStack(spacing: 8) {
                            Text("Route Completed 🎉")
                                .font(.title2.bold())
                                .foregroundColor(Color.green)
                            Text("All stops finished.")
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "map")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.4))
                            Text("No route assigned for today")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.7))
                            Text("Contact your manager if you were expecting one.")
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }

                    Divider().overlay(Color("WRThemeGold")).padding(.horizontal)

                    // MARK: - Shift Start/End (secondary - below the fold)
                    shiftControl

                    if session.assignedRoute != nil {
                        Divider().overlay(Color("WRThemeGold")).padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(session.assignedRoute?.name ?? "Assigned Route")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.8))
                            ProgressView(value: Double(completedCount), total: Double(max(1, totalStops)))
                                .tint(Color("WRThemeGold"))
                            Text(progressText)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 16)
                }
                .padding(.top, 4)
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
    }

    // Name + on-shift status in one compact line instead of a large
    // separate greeting block - frees the collapsed sheet's limited
    // height for the Next Stop card, which is what's actually
    // actionable.
    private var compactHeader: some View {
        HStack {
            if let driver = session.driver {
                Text(driver.name)
                    .font(.headline)
                    .foregroundColor(Color("WRThemeGold"))
                    .lineLimit(1)
            }

            if let shift = session.activeShift, shift.isActive {
                Text("• \(elapsedShiftText)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.green)
            }

            Spacer()

            if embedded {
                NavigationLink {
                    DriverRouteView()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundColor(Color("WRThemeGold"))
                }
                NavigationLink {
                    DriverProfileView()
                } label: {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(Color("WRThemeGold"))
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Shift Control
    // Just the action button - the elapsed time and on-shift status
    // are already shown once, compactly, in the header above. Showing
    // the same giant timer a second time here was pure duplication,
    // not a second piece of information.
    private var shiftControl: some View {
        VStack(spacing: 10) {
            if let shift = session.activeShift, shift.isActive {
                Button {
                    isTogglingShift = true
                    Task {
                        await session.endShift()
                        isTogglingShift = false
                    }
                } label: {
                    Text(isTogglingShift ? "Ending…" : "End Shift")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(14)
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
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color("WRThemeGold"))
                        .foregroundColor(.black)
                        .fontWeight(.bold)
                        .cornerRadius(14)
                }
                .disabled(isTogglingShift)
            }

            if let shiftError = session.shiftError {
                Text(shiftError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
    }
}

