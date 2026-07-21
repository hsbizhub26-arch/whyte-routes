import SwiftUI

struct DriverPin: View {
    let driver: Driver
    
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(Color(hex: driver.colorHex))
                .frame(width: 22, height: 22)
                .shadow(color: Color(hex: "#F5C451").opacity(0.5), radius: 6)
            
            Text(driver.initials)
                .font(.caption2)
                .foregroundColor(.white)
        }
    }
}
