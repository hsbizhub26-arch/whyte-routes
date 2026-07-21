import SwiftUI

struct PillButton: View {

    var title: String
    var action: () -> Void

    var background: Color = Color.black.opacity(0.85)
    var border: Color = Color(hex: "F5C451")

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(
                    Capsule()
                        .fill(background)
                )
                .overlay(
                    Capsule()
                        .stroke(border, lineWidth: 2)
                )
                .shadow(color: border.opacity(0.4), radius: 6, x: 0, y: 4)
        }
    }
}
