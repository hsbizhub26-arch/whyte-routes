import SwiftUI
import UIKit
import CoreLocation

// iPad Phase A helpers. Everything here is a strict no-op on iPhone -
// gated on the device idiom, NOT on horizontalSizeClass, because a Pro
// Max in landscape reports a regular width class too and its layouts
// must not change.

private var isPadIdiom: Bool {
    UIDevice.current.userInterfaceIdiom == .pad
}

// Caps a scroll screen's content column on iPad so cards and forms
// don't stretch edge to edge across a 13" display. Apply it to the
// ScrollView's CONTENT, not the ScrollView, so the scrollable area
// (and the drag that scrolls it) still reaches the screen edges.
struct ReadableContentWidth: ViewModifier {

    static let maxWidth: CGFloat = 700

    func body(content: Content) -> some View {
        if isPadIdiom {
            content
                .frame(maxWidth: Self.maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

// Sign-in / account forms on iPad: a narrow card instead of a 700pt
// column. Even at 700pt, text fields that wide read as a stretched
// phone screen; a 440pt card on a surface reads as a designed one.
// Pair with padCenteredScroll() on the enclosing ScrollView so the card
// sits in the middle of the screen rather than pinned to the top.
struct AuthColumn: ViewModifier {

    func body(content: Content) -> some View {
        if isPadIdiom {
            content
                .frame(maxWidth: 440)
                .padding(.horizontal, 20)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(WRTheme.softBlack.opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(WRTheme.gold.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                .padding(24)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

// The List/Form version. Those own their scroll view, so there is no
// content column to frame - instead the horizontal content margins
// grow until the rows are no wider than ReadableContentWidth.maxWidth.
// Inside an iPad form sheet (already ~700pt) this works out to zero.
struct ReadableListWidth: ViewModifier {

    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if isPadIdiom {
            content
                .contentMargins(
                    .horizontal,
                    max(0, (width - ReadableContentWidth.maxWidth) / 2),
                    for: .scrollContent
                )
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { width = geo.size.width }
                            .onChange(of: geo.size.width) { _, newWidth in width = newWidth }
                    }
                )
        } else {
            content
        }
    }
}

extension View {
    func readableContentWidth() -> some View {
        modifier(ReadableContentWidth())
    }

    func readableListWidth() -> some View {
        modifier(ReadableListWidth())
    }

    // Caps a single card/bar on iPad (the parent stack centres it); a
    // no-op on iPhone, where these already fill the width.
    @ViewBuilder
    func padMaxWidth(_ width: CGFloat) -> some View {
        if isPadIdiom { frame(maxWidth: width) } else { self }
    }

    func authColumn() -> some View {
        modifier(AuthColumn())
    }

    // iPad: content shorter than the screen sits in the vertical middle
    // instead of hugging the top; taller content (keyboard up, landscape)
    // still scrolls normally. nil on iPhone is the system default.
    func padCenteredScroll() -> some View {
        defaultScrollAnchor(isPadIdiom ? .center : nil)
    }

    // A sheet on iPhone; a full-screen cover on iPad. An iPad sheet is a
    // small centred form card - fine for a settings form, wrong for the
    // stop screen (a driver's whole working surface) and for the camera,
    // whose viewfinder shrinks into the card. Everything presented this
    // way already closes itself through `dismiss`, which a full-screen
    // cover honours the same as a sheet.
    @ViewBuilder
    func padFullScreenSheet<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        if isPadIdiom {
            fullScreenCover(item: item, content: content)
        } else {
            sheet(item: item, content: content)
        }
    }

    @ViewBuilder
    func padFullScreenSheet<Sheet: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        if isPadIdiom {
            fullScreenCover(isPresented: isPresented, content: content)
        } else {
            sheet(isPresented: isPresented, content: content)
        }
    }
}

// Auto-arrival only trips on a fix within LocationService's 25m
// accuracy ceiling. A Wi-Fi-only iPad has no GPS chip and locates off
// Wi-Fi networks at ~65m at best, so its geofence can never fire - the
// driver would stand in the driveway waiting for something that isn't
// coming. iOS offers no "has GPS hardware" API, so this reads the
// symptom instead: an iPad whose live fix is too vague for the
// geofence. A cellular iPad with a real GPS lock never sees it.
struct GPSArrivalNotice: View {

    @ObservedObject private var location = LocationService.shared

    private var isShown: Bool {
        guard isPadIdiom, let accuracy = location.currentAccuracy else { return false }
        return accuracy > LocationService.maxUsableAccuracy
    }

    var body: some View {
        if isShown {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "location.slash.fill")
                    .foregroundColor(WRTheme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tap \u{201C}I've Arrived\u{201D} at each stop")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Text("Automatic arrival needs hardware GPS. This iPad's location is too approximate, so arrival won't be detected on its own.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(WRTheme.softBlack)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(WRTheme.gold.opacity(0.4), lineWidth: 1)
            )
        }
    }
}
