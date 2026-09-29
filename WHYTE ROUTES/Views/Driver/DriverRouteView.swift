import SwiftUI

struct DriverRouteView: View {

    @ObservedObject private var session = DriverSession.shared

    @State private var selectedStop: Stop?
    @State private var showStop = false

    var activeStops: [Stop] {
        session.activeStops
    }

    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            VStack(spacing: 16) {

                Text("Your Route")
                    .foregroundColor(Color("WRThemeGold"))
                    .font(.largeTitle.bold())

                if activeStops.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 36))
                            .foregroundColor(Color("WRThemeGold").opacity(0.8))

                        Text("No stops assigned yet")
                            .foregroundColor(.white.opacity(0.7))
                            .font(.headline)
                    }
                    .padding(.top, 40)

                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(activeStops) { stop in
                                stopCard(stop)
                                    .onTapGesture {
                                        selectedStop = stop
                                        showStop = true
                                    }
                            }
                        }
                        .padding(.horizontal)
                        .readableContentWidth()
                    }
                }

                Spacer()
            }
            .padding(.top)
        }
        .padFullScreenSheet(item: $selectedStop) { stop in
            DriverStopView(stop: stop)
        }
    }

    // MARK: - Stop Card
    func stopCard(_ stop: Stop) -> some View {
        HStack(spacing: 16) {

            // Status indicator
            Circle()
                .fill(stop.isCompleted ? .green : Color("WRThemeGold"))
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(stop.customerName ?? "Customer")
                    .foregroundColor(.white)
                    .font(.headline)

                Text(stop.address)
                    .foregroundColor(.white.opacity(0.7))
                    .font(.subheadline)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(Color("WRThemeGold"))
        }
        .padding()
        .background(Color.black.opacity(0.2))
        .cornerRadius(14)
    }
}

