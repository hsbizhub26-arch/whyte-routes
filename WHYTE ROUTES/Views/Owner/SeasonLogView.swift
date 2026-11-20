import SwiftUI

/// B5: Season Log - one gold bar per night worked, snowfall in cm above
/// each bar, bars rise on open, tap a bar for that night's card.
/// Look pending Hope's sign-off (morning review) - doesn't block B6-B9.
struct SeasonLogView: View {
    var demo: SeasonLogRepository.Loaded? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var loaded: SeasonLogRepository.Loaded?
    @State private var selected: String?
    @State private var risen = false
    @State private var editing: SeasonNight?
    @State private var showAllCustomers = false

    private let barWidth: CGFloat = 34
    private let chartHeight: CGFloat = 210
    private static let goldTop = Color(red: 1.0, green: 0.86, blue: 0.45)
    private static let goldBottom = Color(red: 0.72, green: 0.52, blue: 0.10)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let data = loaded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            header(data)
                            chart(data)
                            if let night = data.nights.first(where: { $0.night == selected }) {
                                detailCard(night, data)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            } else if !data.nights.isEmpty {
                                Text("Tap a bar to see that night.")
                                    .font(.footnote).foregroundColor(.secondary)
                            }
                            customers(data)
                        }
                        .padding()
                    }
                } else {
                    ProgressView().tint(WRTheme.gold)
                }
            }
            .navigationTitle("Season Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .sheet(item: $editing) { night in
                OwnerSnowfallEditSheet(night: night, available: loaded?.ownerEditsAvailable ?? false) {
                    Task { await load(keepSelection: true) }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func load(keepSelection: Bool = false) async {
        let data: SeasonLogRepository.Loaded
        if let demo { data = demo } else { data = await SeasonLogRepository().load() }
        await MainActor.run {
            loaded = data
            if !keepSelection { selected = nil; risen = false }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) { risen = true }
        }
    }

    // MARK: Header

    private func header(_ d: SeasonLogRepository.Loaded) -> some View {
        let total = d.nights.compactMap(\.snowfallCm).reduce(0, +)
        return VStack(alignment: .leading, spacing: 6) {
            Text("SEASON \(d.seasonLabel)")
                .font(.caption.bold()).tracking(2).foregroundColor(WRTheme.gold)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(total)").font(.system(size: 44, weight: .heavy, design: .rounded)).foregroundColor(.white)
                Text("cm of snow").font(.title3).foregroundColor(.secondary)
            }
            Text("\(d.nights.count) night\(d.nights.count == 1 ? "" : "s") worked")
                .font(.subheadline).foregroundColor(.secondary)
        }
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(_ d: SeasonLogRepository.Loaded) -> some View {
        if d.nights.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "chart.bar.fill").font(.largeTitle).foregroundColor(WRTheme.gold.opacity(0.5))
                Text("No nights logged yet this season. Each shift adds a bar; drivers enter the snowfall when they end their shift.")
                    .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: chartHeight)
            .padding().background(card)
        } else {
            let maxCm = max(10, d.nights.compactMap(\.snowfallCm).max() ?? 10)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 12) {
                        ForEach(Array(d.nights.enumerated()), id: \.element.id) { i, night in
                            bar(night, maxCm: maxCm, index: i).id(night.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
                .onAppear { proxy.scrollTo(d.nights.last?.id, anchor: .trailing) }
            }
            .background(card)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color(white: 0.06))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(WRTheme.gold.opacity(0.18), lineWidth: 1))
    }

    private func bar(_ n: SeasonNight, maxCm: Int, index: Int) -> some View {
        let isSel = selected == n.night
        let fraction = CGFloat(n.snowfallCm ?? 0) / CGFloat(maxCm)
        let height = n.snowfallCm == nil ? 18 : max(6, chartHeight * fraction)
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selected = isSel ? nil : n.night
            }
        } label: {
            VStack(spacing: 6) {
                Text(n.snowfallCm.map(String.init) ?? "–")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundColor(n.snowfallCm == nil ? .secondary : (isSel ? .white : WRTheme.gold))
                    .opacity(risen ? 1 : 0)
                ZStack(alignment: .bottom) {
                    Color.clear.frame(width: barWidth, height: chartHeight)
                    Group {
                        if n.snowfallCm == nil {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(colors: [Self.goldTop, Self.goldBottom], startPoint: .top, endPoint: .bottom))
                                .shadow(color: WRTheme.gold.opacity(isSel ? 0.7 : 0.25), radius: isSel ? 10 : 4)
                        }
                    }
                    .frame(width: barWidth, height: risen ? height : 0)
                    .animation(.spring(response: 0.8, dampingFraction: 0.72).delay(Double(index) * 0.045), value: risen)
                    .overlay(alignment: .top) {
                        if n.source == .owner && risen {
                            Image(systemName: "pencil.circle.fill").font(.caption2).foregroundColor(.black).padding(.top, 4)
                        }
                    }
                }
                Text(shortDate(n.night))
                    .font(.caption2)
                    .foregroundColor(isSel ? .white : .secondary)
                    .fixedSize()
            }
            .frame(minWidth: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(longDate(n.night)), \(n.snowfallCm.map { "\($0) centimetres" } ?? "snowfall not recorded")")
    }

    // MARK: Detail card

    private func detailCard(_ n: SeasonNight, _ d: SeasonLogRepository.Loaded) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(longDate(n.night)).font(.headline).foregroundColor(.white)
                Spacer()
                Button { withAnimation { selected = nil } } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundColor(.secondary)
                }
                .accessibilityLabel("Close")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n.snowfallCm.map { "\($0) cm" } ?? "Not recorded")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(n.snowfallCm == nil ? .secondary : WRTheme.gold)
                Text(sourceText(n)).font(.caption).foregroundColor(.secondary)
            }
            Divider().background(Color.white.opacity(0.1))
            stat("clock.fill", "Crew hours", String(format: "%.1f h", n.crewHours))
            stat("moon.stars.fill", "Worked", span(n))
            stat("checkmark.circle.fill", "Stops completed", "\(n.stopsCompleted)")
            stat("person.2.fill", "Crew", n.drivers.joined(separator: ", "))
            Button { editing = n } label: {
                Label(n.source == .owner ? "Change snowfall" : "Enter snowfall", systemImage: "pencil")
                    .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 44)
            }
            .foregroundColor(.black).background(WRTheme.gold).cornerRadius(12)
        }
        .padding(16)
        .background(card)
    }

    private func stat(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack {
            Label(label, systemImage: icon).font(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.subheadline.bold()).foregroundColor(.white).multilineTextAlignment(.trailing)
        }
    }

    private func sourceText(_ n: SeasonNight) -> String {
        switch n.source {
        case .owner: return "owner-entered"
        case .drivers:
            return n.driverAnswers.count > 1
                ? "driver-entered (answers: \(n.driverAnswers.map(String.init).joined(separator: ", ")) cm)"
                : "driver-entered"
        case .notRecorded: return "no one entered it"
        }
    }

    // MARK: Customers

    @ViewBuilder
    private func customers(_ d: SeasonLogRepository.Loaded) -> some View {
        if !d.customers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Visits per customer this season").font(.headline).foregroundColor(.white)
                let rows = showAllCustomers ? d.customers : Array(d.customers.prefix(8))
                ForEach(rows) { c in
                    HStack {
                        Text(c.name).foregroundColor(.white).lineLimit(1)
                        Spacer()
                        Text("\(c.visits)").font(.body.bold().monospacedDigit()).foregroundColor(WRTheme.gold)
                    }
                    .padding(.vertical, 4)
                }
                if d.customers.count > 8 {
                    Button(showAllCustomers ? "Show fewer" : "Show all \(d.customers.count)") { showAllCustomers.toggle() }
                        .font(.subheadline).foregroundColor(WRTheme.gold)
                }
            }
            .padding(16)
            .background(card)
        }
    }

    // MARK: Dates

    private static let keyFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private func shortDate(_ key: String) -> String {
        guard let d = Self.keyFormat.date(from: key) else { return key }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
    private func longDate(_ key: String) -> String {
        guard let d = Self.keyFormat.date(from: key) else { return key }
        return "Night of " + d.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
    private func span(_ n: SeasonNight) -> String {
        let s = n.firstStart.formatted(date: .omitted, time: .shortened)
        guard let e = n.lastEnd else { return "\(s) – still running" }
        return "\(s) – \(e.formatted(date: .omitted, time: .shortened))"
    }
}

/// Owner correction for one night, labelled owner-entered.
private struct OwnerSnowfallEditSheet: View {
    let night: SeasonNight
    let available: Bool
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if !available {
                    Section {
                        Text("Owner corrections switch on after the next server update (a security-rules change waiting for approval). Drivers' End Shift answers already work.")
                            .font(.footnote).foregroundColor(.orange)
                    }
                }
                Section {
                    TextField("Snowfall in cm", text: $value).keyboardType(.numberPad)
                } footer: {
                    Text("Shown as owner-entered. It replaces the drivers' answer on the graph; their answers are kept.")
                }
                if let error { Text(error).foregroundColor(.red) }
            }
            .navigationTitle("Snowfall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let cm = Int(value), (0...300).contains(cm) else { error = "Enter centimetres, 0-300."; return }
                        Task {
                            do {
                                try await SeasonLogRepository().saveOwnerSnowfall(night: night.night, cm: cm)
                                await MainActor.run { onSaved(); dismiss() }
                            } catch {
                                await MainActor.run { self.error = "Couldn't save: \(error.localizedDescription)" }
                            }
                        }
                    }
                    .disabled(!available)
                }
            }
            .onAppear { value = night.snowfallCm.map(String.init) ?? "" }
        }
        .presentationDetents([.medium])
    }
}

#if DEBUG
extension SeasonLogRepository.Loaded {
    /// Made-up data for the look review screenshot (launch argument
    /// -SeasonLogDemo, Debug builds only). No real customers.
    static var demo: SeasonLogRepository.Loaded {
        let tz = TimeZone(identifier: "America/Toronto")!
        let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm"
        let plan: [(String, Int?)] = [("11-08", 2), ("11-14", 5), ("11-18", 15), ("11-22", nil), ("11-27", 10),
                                       ("12-03", 25), ("12-09", 5), ("12-15", 20), ("12-21", 8), ("12-29", 12)]
        var shifts: [SeasonShiftInput] = []
        for (day, cm) in plan {
            let start = f.date(from: "2026-\(day) 22:30")!
            shifts.append(SeasonShiftInput(driverId: "a", driverName: "Driver 1", startedAt: start,
                                           endedAt: start.addingTimeInterval(6.5 * 3600), snowfallCm: cm))
            if (cm ?? 0) >= 10 {
                shifts.append(SeasonShiftInput(driverId: "b", driverName: "Driver 2", startedAt: start.addingTimeInterval(3600),
                                               endedAt: start.addingTimeInterval(6 * 3600), snowfallCm: cm.map { $0 - 2 }))
            }
        }
        let names = ["Sample Customer A", "Sample Customer B", "Sample Customer C", "Sample Customer D"]
        var visits: [SeasonVisitInput] = []
        for s in shifts { for (i, n) in names.enumerated() where i <= Int(s.startedAt.timeIntervalSince1970) % 4 {
            visits.append(SeasonVisitInput(customerId: "\(i)", customerName: n, completedAt: s.startedAt.addingTimeInterval(Double(i + 1) * 1800)))
        } }
        return .init(nights: SeasonLogBuilder.nights(shifts: shifts, visits: visits,
                                                     overrides: ["2026-12-09": SeasonOverride(cm: 7, enteredAt: nil)], timeZone: tz),
                     customers: SeasonLogBuilder.customerCounts(visits), seasonLabel: "2026-2027", ownerEditsAvailable: false)
    }
}
#endif
