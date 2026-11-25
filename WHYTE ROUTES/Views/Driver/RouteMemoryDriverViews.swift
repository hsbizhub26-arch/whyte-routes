import SwiftUI

// MARK: - Predicted time + basis label (under each stop)

struct PredictionLine: View {
    let stop: Stop
    @ObservedObject private var rm = RouteMemoryService.shared

    var body: some View {
        let p = rm.prediction(for: stop)
        VStack(alignment: .leading, spacing: 1) {
            Label("About \(RouteMemoryCore.formatWork(p.sec))", systemImage: "clock")
                .font(.caption.weight(.semibold))
            Text(p.basis)
                .font(.caption2)
                .opacity(0.7)
        }
        .foregroundColor(.white.opacity(0.85))
    }
}

// MARK: - Reason chips (optional - never blocks Complete)

struct ReasonChips: View {
    let selected: String?
    @Binding var otherText: String
    let onSelect: (String, String?) -> Void

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(RouteMemoryCore.reasonOrder, id: \.self) { code in
                    let isOn = selected == code
                    Button {
                        onSelect(code, code == "other" ? otherText : nil)
                    } label: {
                        Text(RouteMemoryCore.reasonLabels[code] ?? code)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .padding(.horizontal, 6)
                            .background(isOn ? Color("WRThemeGold") : Color.black.opacity(0.35))
                            .foregroundColor(isOn ? .black : .white)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color("WRThemeGold").opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            if selected == "other" {
                HStack {
                    TextField("What happened? (80 characters)", text: $otherText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: otherText) { _, new in
                            if new.count > RouteMemory.REASON_OTHER_MAX_CHARS {
                                otherText = String(new.prefix(RouteMemory.REASON_OTHER_MAX_CHARS))
                            }
                        }
                        .submitLabel(.done)
                        .onSubmit { onSelect("other", otherText) }
                    Button("Save") { onSelect("other", otherText) }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

/// Shown at Complete for a stop that is running well over its usual time.
/// Optional: "Complete" is always available and the reason can be skipped.
struct ReasonSheet: View {
    @ObservedObject var vm: DriverStopViewModel
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This one took longer than usual")
                .font(.title3.bold())
            Text("Tap a reason if you like - it's optional and you can skip it.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            ReasonChips(selected: vm.reasonCode, otherText: $vm.reasonText) { code, text in
                vm.chooseReason(code, text: text)
            }
            Spacer(minLength: 0)
            Button(action: onComplete) {
                Text(vm.reasonCode == nil ? "Skip and complete" : "Complete")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color("WRThemeGold"))
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}

// MARK: - Run setup (Start Shift): summary + Heavy snow toggle

struct RunSetupSheet: View {
    @ObservedObject private var session = DriverSession.shared
    @ObservedObject private var rm = RouteMemoryService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var heavySnow = false
    @State private var starting = false

    private var pending: [Stop] { session.activeStops.filter { $0.isPending } }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if let name = session.assignedRoute?.name {
                    Text(name).font(.title2.bold())
                }
                // Re-evaluated every minute so "estimated finish" tracks the clock.
                TimelineView(.everyMinute) { context in
                    let sum = rm.summary(for: pending, snow: heavySnow, start: context.date)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sum.text).font(.headline)
                        Text("Smart predictions - learned from your shifts. Drive time isn't included.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Toggle(isOn: $heavySnow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heavy snow tonight").font(.headline)
                        Text("Adds 30% to tonight's estimates only. It never changes what the app has learned.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(Color("WRThemeGold"))
                Spacer(minLength: 0)
                Button {
                    starting = true
                    Task {
                        await session.startShift(snow: heavySnow)
                        starting = false
                        dismiss()
                    }
                } label: {
                    Text(starting ? "Starting…" : "Start Shift")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color("WRThemeGold"))
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(starting)
            }
            .padding(20)
            .navigationTitle("Start Shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await rm.loadStats(for: pending) }
        }
        .presentationDetents([.medium, .large])
    }
}
