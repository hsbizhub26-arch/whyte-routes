import SwiftUI

struct PillButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundColor(.black)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Color(hex: "#F5C451"))
                .cornerRadius(40)
                .shadow(color: Color(hex: "#F5C451").opacity(0.4), radius: 8)
        }
        .padding(.horizontal)
    }
}
