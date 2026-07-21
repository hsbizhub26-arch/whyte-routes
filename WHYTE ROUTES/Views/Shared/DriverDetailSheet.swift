import SwiftUI

struct DriverDetailSheet: View {
    let driver: Driver
    let onClose: () -> Void
    
    var body: some View {
        VStack(spacing: 18) {
            
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 80, height: 6)
                .padding(.top, 8)
            
            Text(driver.name)
                .foregroundColor(.white)
                .font(.title2)
                .bold()
            
            HStack {
                StatusBadge(label: driver.clockedIn ? "Clocked In" : "Offline",
                             color: driver.clockedIn ? .green : .red)
                Spacer()
            }.padding(.horizontal)
            
            InfoRow(label: "Next Stop", value: driver.nextStopAddress)
            InfoRow(label: "Time at Stop", value: driver.timerFormatted)
            InfoRow(label: "Total Stops Done", value: "\(driver.completedStops)")
            
            GoldButton(title: "VIEW DRIVER REPORT") {
                onClose()
                DriverService.shared.openDriverReport(driver)
            }
            
            GoldButton(title: "CLOSE") {
                onClose()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(Color.black.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(Color(hex: "#F5C451").opacity(0.15), lineWidth: 1.5)
                )
        )
        .shadow(color: Color(hex: "#F5C451").opacity(0.25), radius: 14)
        .padding()
    }
}
