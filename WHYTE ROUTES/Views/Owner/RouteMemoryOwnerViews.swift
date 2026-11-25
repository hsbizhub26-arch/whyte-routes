import SwiftUI

// MARK: - Shift History, Run Detail, Visit History

/// Red "2.00x usual" tag - the visit's STORED ratio, two decimals.
struct FlagTag: View {
    let ratio: Double
    var body: some View {
        Text(RouteMemoryCore.formatFlagTag(ratio))
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.red.opacity(0.9))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }
}

private func clock(_ d: Date?) -> String {
    d.map { RouteMemoryCore.formatLocalTime($0, tz: RouteMemoryHistory.timeZoneId) } ?? "-"
}
private func dayText(_ d: Date) -> String {
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: RouteMemoryHistory.timeZoneId) ?? .current
    f.dateFormat = "EEE, MMM d"
    return f.string(from: d)
}
private func hm(_ sec: Int?) -> String {
    guard let sec else { return "-" }
    return RouteMemoryCore.formatWork(Double(sec))
}

/// Past runs. Owners and managers see every driver (read-only); a driver
/// sees their own - pass `onlyDriver` for that.
struct ShiftHistoryView: View {
    var onlyDriver: String? = nil
    @State private var runs: [RunItem] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && runs.isEmpty {
                Text("No runs yet. A run is recorded each time a driver starts a shift on a route.")
                    .foregroundColor(.secondary)
            }
            ForEach(runs) { run in
                NavigationLink {
                    RunDetailView(run: run, onlyDriver: onlyDriver)
                } label: {
                    RunRowView(run: run, onlyDriver: onlyDriver)
                }
            }
        }
        .navigationTitle("Shift History")
        .overlay { if !loaded { ProgressView() } }
        .task {
            runs = await RouteMemoryHistory.runs(onlyDriver: onlyDriver)
            loaded = true
        }
    }
}

struct RunRowView: View {
    let run: RunItem
    let onlyDriver: String?
    @State private var row: RunRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(dayText(run.startedAt)).font(.headline)
                if run.snowActive { Image(systemName: "snowflake").foregroundColor(.cyan) }
                Spacer()
                if run.endedAt == nil { Text("In progress").font(.caption).foregroundColor(.orange) }
            }
            Text("\(run.driverName) · \(run.routeName)").font(.subheadline).foregroundColor(.secondary)
            if let row {
                Text("\(row.stopsCompleted) done · \(row.stopsSkipped) skipped · \(hm(row.totalTimeSec)) on route"
                     + (row.avgPerStopSec.map { " · \(RouteMemoryCore.formatMinSec($0)) per stop" } ?? ""))
                    .font(.footnote)
            } else {
                Text("\(run.stopCount) stops planned").font(.footnote).foregroundColor(.secondary)
            }
        }
        .task {
            let visits = await RouteMemoryHistory.visits(runId: run.id, onlyDriver: onlyDriver)
            row = RouteMemoryCore.runRow(startedAt: run.startedAt, endedAt: run.endedAt,
                                         visits: visits.map(\.record), now: Date())
        }
    }
}

struct RunDetailView: View {
    let run: RunItem
    let onlyDriver: String?
    @State private var visits: [VisitItem] = []
    @State private var loaded = false
    @State private var csvURL: URL?
    @State private var showShare = false

    var body: some View {
        List {
            Section {
                Text("\(run.driverName) · \(run.routeName)")
                Text("Started \(clock(run.startedAt))" + (run.endedAt.map { " · ended \(clock($0))" } ?? " · in progress"))
                    .font(.footnote).foregroundColor(.secondary)
                if run.snowActive {
                    Label("Heavy snow was on - this run's estimates were scaled up 30%", systemImage: "snowflake")
                        .font(.footnote).foregroundColor(.cyan)
                }
            }
            Section("Stops") {
                if loaded && visits.isEmpty { Text("No stops recorded for this run.").foregroundColor(.secondary) }
                ForEach(visits) { visit in stopRow(visit.record) }
            }
        }
        .navigationTitle(dayText(run.startedAt))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { exportCSV() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(visits.isEmpty)
            }
        }
        .sheet(isPresented: $showShare) {
            if let csvURL { RouteMemoryShareSheet(url: csvURL) }
        }
        .task {
            visits = await RouteMemoryHistory.visits(runId: run.id, onlyDriver: onlyDriver)
            loaded = true
        }
    }

    private func stopRow(_ v: VisitRecord) -> some View {
        let status = RouteMemoryCore.effectiveStatus(v, now: Date())
        let dur = RouteMemoryCore.durationSec(v)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(v.address).font(.subheadline.weight(.semibold))
                Spacer()
                if v.flagged == true, let r = v.flagRatio { FlagTag(ratio: r) }
            }
            if status == "completed" {
                Text("Start \(clock(v.correctedArrivedAt ?? v.arrivedAt)) · Done \(clock(v.correctedCompletedAt ?? v.completedAt))"
                     + (dur.map { " · \(RouteMemoryCore.formatMinSec($0))" } ?? ""))
                    .font(.footnote)
            } else {
                Text(status.capitalized).font(.footnote).foregroundColor(.secondary)
            }
            if v.flagged == true {
                let reason = RouteMemoryCore.reasonLabel(v)
                if !reason.isEmpty { Text("Reason: \(reason)").font(.footnote).foregroundColor(.orange) }
            }
            if v.correctedOutcome != nil || v.correctedCompletedAt != nil || v.correctedArrivedAt != nil {
                Text("Corrected by the owner").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private func exportCSV() {
        let csv = RouteMemoryCore.buildRunCsv(visits.map(\.record), tz: RouteMemoryHistory.timeZoneId, now: Date())
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(f.string(from: run.startedAt))-\(run.id.prefix(6)).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            csvURL = url
            showShare = true
        } catch {
            print("⚠️ RouteMemory: couldn't write CSV: \(error.localizedDescription)")
        }
    }
}

/// Every past visit of one property (staff only).
struct VisitHistoryView: View {
    let propertyKey: String
    let title: String
    @State private var visits: [VisitItem] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && visits.isEmpty { Text("No visits recorded yet.").foregroundColor(.secondary) }
            ForEach(visits) { item in
                let v = item.record
                let status = RouteMemoryCore.effectiveStatus(v, now: Date())
                let dur = RouteMemoryCore.durationSec(v)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text((v.arrivedAt ?? v.createdAt).map(dayText) ?? (item.serviceDate ?? "Visit"))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if v.flagged == true, let r = v.flagRatio { FlagTag(ratio: r) }
                    }
                    Text(status == "completed"
                         ? (dur.map { "Took \(RouteMemoryCore.formatMinSec($0))" } ?? "Completed")
                         : status.capitalized)
                        .font(.footnote)
                    if v.driverName.isEmpty == false { Text(v.driverName).font(.caption).foregroundColor(.secondary) }
                    if v.flagged == true {
                        let reason = RouteMemoryCore.reasonLabel(v)
                        if !reason.isEmpty { Text("Reason: \(reason)").font(.footnote).foregroundColor(.orange) }
                    }
                }
            }
        }
        .navigationTitle(title)
        .overlay { if !loaded { ProgressView() } }
        .task {
            visits = await RouteMemoryHistory.visits(propertyKey: propertyKey)
            loaded = true
        }
    }
}

/// iOS share sheet for the exported CSV.
struct RouteMemoryShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
