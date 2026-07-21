import SwiftUI

struct SubscriptionTierView: View {

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color("WRBlack")],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            ScrollView(spacing: 30) {
                VStack(spacing: 20) {

                    Text("Unlock Whyte Routes Premium")
                        .font(.largeTitle.bold())
                        .foregroundColor(Color("WRThemeGold"))
                        .padding(.top, 40)

                    tierCard(
                        title: "PREMIUM",
                        price: "$149 / month",
                        yearly: "$1499 / year",
                        features: [
                            "✓ Route Optimization",
                            "✓ Analytics Dashboard",
                            "✓ Customer Tracking Links"
                        ],
                        gold: false
                    )

                    tierCard(
                        title: "PREMIUM PLUS",
                        price: "$229 / month",
                        yearly: "$1999 / year",
                        features: [
                            "✓ ALL Premium Features",
                            "✓ Live Driver Tracking",
                            "✓ Multi-Driver Routes",
                            "✓ Manager Tools",
                            "✓ Dispatch Alerts"
                        ],
                        gold: true
                    )

                    Spacer()
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Card Builder
    func tierCard(title: String, price: String, yearly: String, features: [String], gold: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            Text(title)
                .font(.title.bold())
                .foregroundColor(gold ? Color("WRThemeGold") : .white)

            Text(price)
                .font(.title3.bold())
                .foregroundColor(.white)

            Text("or \(yearly) billed yearly")
                .font(.caption)
                .foregroundColor(.gray)

            Divider().background(Color.gray)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(features, id: \.self) { feature in
                    Text(feature)
                        .foregroundColor(.white)
                        .font(.subheadline)
                }
            }

            Button(action: {}) {
                Text("Subscribe")
                    .font(.headline.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(gold ? Color("WRThemeGold") : .white.opacity(0.15))
                    .foregroundColor(gold ? .black : .white)
                    .cornerRadius(14)
            }
            .padding(.top, 10)

        }
        .padding()
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(gold ? Color("WRThemeGold") : Color.white.opacity(0.2), lineWidth: gold ? 2 : 1)
        )
        .cornerRadius(20)
    }
}
