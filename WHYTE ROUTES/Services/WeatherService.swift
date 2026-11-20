import Foundation
import CoreLocation
import Combine

// B3: weather strip.
//
// SOURCE: Environment and Climate Change Canada's city-page forecasts
// (api.weather.gc.ca, collection citypageweather-realtime), under the
// Open Government Licence - Canada: free, no API key, commercial use
// allowed with attribution (shown on the strip).
//
// NOT Open-Meteo, although the brief named it: Open-Meteo's free API is
// for non-commercial use only (open-meteo.com/en/terms, checked
// 2026-11-19), and Whyte Routes is a paid product; its commercial plan
// costs money, which the $0 budget rules out. ECCC covers Canada only -
// outside Canada the strip simply hides (Ontario-first launch).
//
// One small request per 30 minutes per phone. Only a rounded position
// is sent; nothing about the company or its customers.

struct WeatherSnapshot: Equatable {
    let placeName: String
    let temperatureC: Double?
    let condition: String
    /// ECCC's own snow accumulation for today + tonight, cm. Nil when
    /// the forecast gives no amount.
    let snowNext24hCm: Double?
    /// Snow or flurries mentioned in the next 24 hourly forecasts.
    let snowLikely: Bool
    /// First hourly forecast mentioning snow, if any.
    let snowStartsAt: Date?
    let lowNext24hC: Double?
    let fetchedAt: Date

    var symbol: String {
        let c = condition.lowercased()
        if c.contains("snow") || c.contains("flurr") || c.contains("ice pellet") { return "cloud.snow.fill" }
        if c.contains("freezing") { return "cloud.sleet.fill" }
        if c.contains("thunder") { return "cloud.bolt.rain.fill" }
        if c.contains("rain") || c.contains("shower") || c.contains("drizzle") { return "cloud.rain.fill" }
        if c.contains("fog") || c.contains("mist") || c.contains("haze") { return "cloud.fog.fill" }
        if c.contains("sunny") || c.contains("clear") {
            return c.contains("mainly") || c.contains("mix") ? "cloud.sun.fill" : "sun.max.fill"
        }
        if c.contains("cloud") { return "cloud.fill" }
        return "cloud.sun.fill"
    }

    private static func mentionsSnow(_ s: String) -> Bool {
        let c = s.lowercased()
        return c.contains("snow") || c.contains("flurr")
    }

    /// Parses one GeoJSON feature from the ECCC city-page collection.
    /// Pure, so it's testable.
    static func parse(feature: [String: Any], now: Date = Date()) -> WeatherSnapshot? {
        guard let p = feature["properties"] as? [String: Any] else { return nil }
        func en(_ any: Any?) -> Any? { (any as? [String: Any])?["en"] }
        func num(_ any: Any?) -> Double? { (en(any) as? NSNumber)?.doubleValue }

        let name = (en(p["name"]) as? String) ?? ""
        let current = p["currentConditions"] as? [String: Any]
        let temp = num((current?["temperature"] as? [String: Any])?["value"])
        var condition = (en(current?["condition"]) as? String) ?? ""

        let iso = ISO8601DateFormatter()
        let hourly = ((p["hourlyForecastGroup"] as? [String: Any])?["hourlyForecasts"] as? [[String: Any]]) ?? []
        var low: Double?
        var starts: Date?
        var likely = false
        let horizon = now.addingTimeInterval(24 * 3600)
        for h in hourly {
            guard let ts = h["timestamp"] as? String, let at = iso.date(from: ts) else { continue }
            guard at.addingTimeInterval(3600) > now, at < horizon else { continue }
            if let t = num((h["temperature"] as? [String: Any])?["value"]) { low = min(low ?? t, t) }
            let cond = (en(h["condition"]) as? String) ?? ""
            if condition.isEmpty { condition = cond }
            if mentionsSnow(cond) {
                likely = true
                if starts == nil { starts = at }
            }
        }

        // Today + tonight (the first two periods) ~ the next 24 hours.
        let periods = ((p["forecastGroup"] as? [String: Any])?["forecasts"] as? [[String: Any]]) ?? []
        var snowCm: Double?
        for f in periods.prefix(2) {
            if let acc = (f["precipitation"] as? [String: Any])?["accumulation"] as? [String: Any],
               (en(acc["name"]) as? String)?.lowercased() == "snow",
               let cm = num((acc["amount"] as? [String: Any])?["value"]) {
                snowCm = (snowCm ?? 0) + cm
                likely = true
            }
            if let text = en(f["textSummary"]) as? String, mentionsSnow(text) { likely = true }
        }

        guard temp != nil || !hourly.isEmpty else { return nil }
        return WeatherSnapshot(placeName: name, temperatureC: temp, condition: condition.isEmpty ? "—" : condition,
                               snowNext24hCm: snowCm, snowLikely: likely, snowStartsAt: starts,
                               lowNext24hC: low, fetchedAt: now)
    }

    /// Nearest feature to a coordinate in an ECCC items response.
    static func nearest(in data: Data, to c: CLLocationCoordinate2D) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return nil }
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return features.min { a, b in
            dist(a, here) < dist(b, here)
        }
    }

    private static func dist(_ f: [String: Any], _ here: CLLocation) -> CLLocationDistance {
        guard let g = f["geometry"] as? [String: Any], let xy = g["coordinates"] as? [NSNumber], xy.count >= 2 else {
            return .greatestFiniteMagnitude
        }
        return CLLocation(latitude: xy[1].doubleValue, longitude: xy[0].doubleValue).distance(from: here)
    }
}

@MainActor
final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var failed = false
    private var lastKey: String?
    private var inFlight = false

    /// Refreshes if the reading is over 30 minutes old or the position
    /// moved ~5 km. Silent on failure: the strip hides - weather is a
    /// convenience, never a blocker.
    func refresh(for coordinate: CLLocationCoordinate2D) {
        let lat = (coordinate.latitude * 20).rounded() / 20
        let lon = (coordinate.longitude * 20).rounded() / 20
        let key = "\(lat),\(lon)"
        if key == lastKey, let s = snapshot, Date().timeIntervalSince(s.fetchedAt) < 1800 { return }
        guard !inFlight else { return }
        inFlight = true
        let point = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        Task {
            defer { inFlight = false }
            // Nearby forecast sites first, then a wider box for rural areas.
            for pad in [0.5, 1.5] {
                var comps = URLComponents(string: "https://api.weather.gc.ca/collections/citypageweather-realtime/items")!
                comps.queryItems = [
                    .init(name: "f", value: "json"),
                    .init(name: "lang", value: "en"),
                    .init(name: "limit", value: "30"),
                    .init(name: "bbox", value: "\(lon - pad),\(lat - pad),\(lon + pad),\(lat + pad)")
                ]
                guard let url = comps.url,
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                if let feature = WeatherSnapshot.nearest(in: data, to: point),
                   let parsed = WeatherSnapshot.parse(feature: feature) {
                    snapshot = parsed
                    lastKey = key
                    failed = false
                    return
                }
            }
            failed = true
        }
    }
}
