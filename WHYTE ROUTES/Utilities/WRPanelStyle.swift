import SwiftUI

struct WRPanelStyle: ViewModifier {

    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                LinearGradient(colors: [
                    Color.black.opacity(0.95),
                    Color.black.opacity(0.80)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(hex: "F5C451").opacity(0.6), lineWidth: 1.5)
            )
            .shadow(color: Color(hex: "F5C451").opacity(0.25), radius: 12, x: 0, y: 6)
    }
}

extension View {
    func wrPanel() -> some View {
        self.modifier(WRPanelStyle())
    }
}
