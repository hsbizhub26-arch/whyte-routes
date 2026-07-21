import SwiftUI

struct SecondaryGoldButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color("WRThemeGold"))
                .frame(maxWidth: .infinity)
                .frame(height: 55)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color("WRDeepBlack"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color("WRThemeGold"), lineWidth: 1)
                        )
                )
                .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
    }
}
