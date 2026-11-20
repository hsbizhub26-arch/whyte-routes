import SwiftUI
import CoreLocation

/// B3: one-line weather for the crew's area - what matters on a snow or
/// landscaping night: is snow coming, how much, when it starts, how cold
/// it gets. Uses the phone's own location; hides itself when there's no
/// location, the phone is outside Canada, or the forecast can't load.
struct WeatherStripView: View {
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var location = LocationService.shared

    var body: some View {
        Group {
            if let s = weather.snapshot {
                content(s)
            } else if coordinate != nil && !weather.failed {
                HStack(spacing: 8) {
                    ProgressView().tint(WRTheme.gold)
                    Text("Loading weather…").font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: location.currentLocation?.latitude) { _, _ in refresh() }
    }

    /// Live GPS while a shift is running; otherwise the phone's last
    /// known position (owners don't stream location off-shift). No new
    /// permission and no extra tracking - just the cached fix.
    private var coordinate: CLLocationCoordinate2D? {
        location.currentLocation ?? CLLocationManager().location?.coordinate
    }

    private func refresh() {
        if let c = coordinate { weather.refresh(for: c) }
    }

    private func content(_ s: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: s.symbol)
                    .font(.title2)
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(s))
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subline(s))
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snowAmount(s))
                        .font(.subheadline.bold())
                        .foregroundColor(s.snowLikely ? WRTheme.gold : .secondary)
                    Text(s.snowLikely ? snowStartText(s) : "next 24 h")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Text("Environment Canada forecast · Contains information licensed under the Open Government Licence – Canada.")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(s.snowLikely ? WRTheme.gold.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func headline(_ s: WeatherSnapshot) -> String {
        if let t = s.temperatureC { return "\(Int(t.rounded()))° · \(s.condition)" }
        return s.condition
    }

    private func subline(_ s: WeatherSnapshot) -> String {
        var parts: [String] = []
        if let low = s.lowNext24hC { parts.append("Low \(Int(low.rounded()))°") }
        if !s.placeName.isEmpty { parts.append(s.placeName) }
        return parts.joined(separator: " · ")
    }

    private func snowAmount(_ s: WeatherSnapshot) -> String {
        guard s.snowLikely else { return "No snow" }
        if let cm = s.snowNext24hCm, cm >= 1 { return "\(Int(cm.rounded())) cm snow" }
        return "Snow likely"
    }

    private func snowStartText(_ s: WeatherSnapshot) -> String {
        guard let start = s.snowStartsAt else { return "next 24 h" }
        if start <= Date() { return "snowing now" }
        return "from \(start.formatted(date: .omitted, time: .shortened))"
    }
}
