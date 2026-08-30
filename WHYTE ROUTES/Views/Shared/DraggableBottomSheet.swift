import SwiftUI

// A persistent bottom panel that drags between snap points like a
// system sheet, but is ordinary view layout inside the ZStack rather
// than an actual .sheet() presentation. A real .sheet() always covers
// the enclosing TabView's own tab bar completely - that broke
// navigation to every other tab the moment the map-first Home screens
// tried using one for their widget panel. This stays correctly
// bounded above the tab bar because it's just a view, not a modal.
//
// Positioned with a Spacer rather than a .frame(alignment:) trick -
// Spacer is guaranteed to have no hit-testable content, so the space
// above the panel reliably passes taps through to the map (and the
// tab bar below the map's own bounds) instead of an earlier version
// where the panel's oversized layout frame silently ate every touch
// on the whole screen.
struct DraggableBottomSheet<Content: View>: View {

    enum Detent: CaseIterable {
        case collapsed, medium, large
    }

    let collapsedHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var detent: Detent = .collapsed
    @GestureState private var dragTranslation: CGFloat = 0

    private func targetHeight(_ detent: Detent, containerHeight: CGFloat) -> CGFloat {
        switch detent {
        case .collapsed: return collapsedHeight
        case .medium: return containerHeight * 0.5
        case .large: return containerHeight * 0.9
        }
    }

    var body: some View {
        GeometryReader { geo in
            let baseHeight = targetHeight(detent, containerHeight: geo.size.height)
            let liveHeight = min(
                targetHeight(.large, containerHeight: geo.size.height),
                max(collapsedHeight, baseHeight - dragTranslation)
            )

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    // THE HANDLE OWNS THE GESTURE, not the whole panel.
                    //
                    // The drag used to be attached to the entire sheet,
                    // content included - so every swipe was a fight
                    // between moving the sheet and scrolling what was
                    // inside it. SwiftUI resolves that contest
                    // arbitrarily, which is why it felt like the sheet
                    // "sometimes" dragged and the list "sometimes"
                    // scrolled. Confining the gesture to this strip
                    // means the two can never compete: the handle
                    // moves the sheet, everything below it scrolls.
                    //
                    // A 44pt tall strip with contentShape() so the
                    // whole width is grabbable, not just the 40x5
                    // capsule - the capsule is the affordance, not the
                    // target.
                    VStack(spacing: 0) {
                        Capsule()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 40, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .updating($dragTranslation) { value, state, _ in
                                state = value.translation.height
                            }
                            .onEnded { value in
                                let projected = baseHeight - value.translation.height
                                let candidate = Detent.allCases.min { a, b in
                                    abs(targetHeight(a, containerHeight: geo.size.height) - projected)
                                        < abs(targetHeight(b, containerHeight: geo.size.height) - projected)
                                }
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    detent = candidate ?? .collapsed
                                }
                            }
                    )
                    // Tap is the quick path, and the one most people
                    // reach for: collapsed opens, anything else closes.
                    // Dragging still gives the in-between size for
                    // anyone who wants it, but nobody has to drag to
                    // get the sheet out of the way of the map.
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            detent = (detent == .collapsed) ? .medium : .collapsed
                        }
                    }

                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                .frame(height: liveHeight, alignment: .top)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black)
                )
                .shadow(color: .black.opacity(0.3), radius: 12, y: -4)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detent)
            }
        }
    }
}
