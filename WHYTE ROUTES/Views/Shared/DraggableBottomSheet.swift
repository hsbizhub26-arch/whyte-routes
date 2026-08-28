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
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 40, height: 5)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

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
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detent)
            }
        }
    }
}
