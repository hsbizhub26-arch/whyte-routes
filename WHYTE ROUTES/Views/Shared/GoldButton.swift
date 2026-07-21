import SwiftUI

struct GoldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.wrDeepBlack.opacity(0.9))
            .foregroundColor(WRTheme.gold)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(WRTheme.gold, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// A labeled gold button used throughout Owner/Onboarding screens.
struct GoldButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.bold)
        }
        .buttonStyle(GoldButtonStyle())
    }
}
