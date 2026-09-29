import SwiftUI

struct SMSButton: View {

    let title: String
    let phone: String
    let link: String
    var driverName: String? = nil
    var etaMinutes: Int? = nil

    @State private var isPressed = false
    @State private var isLoading = false
    @State private var showCannotText = false

    private var isDisabled: Bool {
        phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button(action: sendSMS) {
            ZStack {
                Text(title)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.black.opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(WRTheme.gold.opacity(0.85), lineWidth: 2)
                    )
                    .shadow(color: WRTheme.gold.opacity(0.25),
                            radius: 10, x: 0, y: 6)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(WRTheme.gold)
                }
            }
        }
        .scaleEffect(isPressed ? 0.97 : 1)
        .opacity(isDisabled ? 0.5 : 1)
        .disabled(isDisabled)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isDisabled { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .alert("Can't send texts from this device", isPresented: $showCannotText) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device has no messaging set up. Send the tracking link from a phone instead.")
        }
    }

    private func sendSMS() {
        guard !isDisabled else { return }

        isLoading = true

        SMSService.shared.sendSMS(
            phone: phone,
            link: link,
            driverName: driverName,
            etaMinutes: etaMinutes,
            onFailure: {
                isLoading = false
                showCannotText = true
            }
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isLoading = false
        }
    }
}
