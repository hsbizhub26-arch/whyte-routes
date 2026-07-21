import SwiftUI

struct ManagerDriverCard: View {

    let driver: Driver
    let tapAction: () -> Void

    var body: some View {
        Button(action: tapAction) {
            HStack {
                VStack(alignment: .leading) {
                    Text(driver.name)
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(driver.vehicle)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(Color("WRThemeGold"))
            }
            .padding()
            .background(Color("WRBlackSecondary"))
            .cornerRadius(16)
        }
    }
}
