import SwiftUI

/// B5: "How much snow tonight?" - shown right AFTER a shift has ended
/// (Oct 15 - Apr 30 only). The shift is already closed when this
/// appears, so skipping or closing it can never hold up clocking out.
struct SnowfallPromptSheet: View {
    let driverId: String
    let shiftId: String
    @Environment(\.dismiss) private var dismiss

    @State private var custom = ""
    @State private var showCustom = false
    @State private var saving = false
    @State private var error: String?

    private let presets = [2, 5, 10, 15, 20]

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 40, height: 5).padding(.top, 8)
            VStack(spacing: 6) {
                Image(systemName: "cloud.snow.fill").font(.system(size: 34)).foregroundColor(WRTheme.gold)
                Text("Shift ended").font(.headline).foregroundColor(.white)
                Text("How much snow fell tonight? It builds your Season Log.")
                    .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(presets, id: \.self) { cm in chip("\(cm) cm") { save(cm) } }
                chip("25+ cm") { showCustom = true; custom = "25" }
            }
            if showCustom {
                HStack {
                    TextField("cm", text: $custom)
                        .keyboardType(.numberPad)
                        .font(.title3.bold())
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(12)
                    Button("Save") {
                        if let v = Int(custom.trimmingCharacters(in: .whitespaces)), (0...300).contains(v) { save(v) }
                        else { error = "Enter centimetres, 0-300." }
                    }
                    .bold().padding(.horizontal, 18).padding(.vertical, 12)
                    .background(WRTheme.gold).foregroundColor(.black).cornerRadius(12)
                }
            } else {
                Button("Other amount") { showCustom = true }
                    .font(.subheadline).foregroundColor(WRTheme.gold)
            }
            if let error { Text(error).font(.caption).foregroundColor(.red) }
            Button("Skip") { dismiss() }
                .font(.subheadline).foregroundColor(.secondary)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .disabled(saving)
        .presentationDetents([.medium])
        .presentationBackground(Color.black)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.white.opacity(0.07))
                .foregroundColor(.white)
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(WRTheme.gold.opacity(0.6), lineWidth: 1))
        }
    }

    private func save(_ cm: Int) {
        saving = true
        Task {
            do {
                try await ShiftRepository().setSnowfall(driverId: driverId, shiftId: shiftId, cm: cm)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    saving = false
                    self.error = "Couldn't save - the shift is still ended. You can add it later from the Season Log."
                }
            }
        }
    }
}
