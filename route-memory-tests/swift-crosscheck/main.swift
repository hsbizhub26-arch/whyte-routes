import Foundation

// Runs the app's Route Memory logic on fixtures.json and prints the results as JSON.
func d(_ ms: Any?) -> Date? { (ms as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
let fx = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
var out: [String: Any] = [:]

out["predict"] = (fx["predict"] as! [[String: Any]]).map { c -> [String: Any] in
    let tier = (c["tier"] as? String).flatMap(SizeTier.init(rawValue:))
    let stats = PropertyStats(visitCount: (c["count"] as! NSNumber).intValue, avgDurationSec: (c["avg"] as? NSNumber)?.doubleValue)
    let p = RouteMemoryCore.predict(stats: stats.visitCount == 0 ? nil : stats, tier: tier, snow: c["snow"] as! Bool)
    return ["sec": p.sec, "basis": p.basis]
}
out["flagTag"] = (fx["flagTag"] as! [NSNumber]).map { RouteMemoryCore.formatFlagTag($0.doubleValue) }
out["willFlag"] = (fx["willFlag"] as! [[String: Any]]).map {
    RouteMemoryCore.willFlag(elapsedSec: ($0["elapsed"] as! NSNumber).doubleValue, avgSec: ($0["avg"] as? NSNumber)?.doubleValue, visitCount: ($0["count"] as! NSNumber).intValue)
}
out["times"] = (fx["times"] as! [[String: Any]]).map { t -> [String: String] in
    let date = d(t["ms"])!, tz = t["tz"] as! String
    return ["time": RouteMemoryCore.formatLocalTime(date, tz: tz), "dateTime": RouteMemoryCore.formatLocalDateTime(date, tz: tz)]
}
out["work"] = (fx["work"] as! [NSNumber]).map { RouteMemoryCore.formatWork($0.doubleValue) }
out["minSec"] = (fx["minSec"] as! [NSNumber]).map { RouteMemoryCore.formatMinSec($0.doubleValue) }
out["summary"] = (fx["summary"] as! [[String: Any]]).map { s -> [String: Any] in
    let r = RouteMemoryCore.runSummary(stopCount: (s["stopCount"] as! NSNumber).intValue, totalServiceSec: (s["totalSec"] as! NSNumber).doubleValue,
                                       start: d(s["startMs"])!, tz: s["tz"] as! String, driveSec: (s["driveSec"] as? NSNumber)?.doubleValue)
    return ["finishMs": Int((r.finish.timeIntervalSince1970 * 1000).rounded()), "text": r.text]
}
func visit(_ v: [String: Any]) -> VisitRecord {
    var r = VisitRecord()
    r.address = v["address"] as? String ?? ""; r.driverName = v["driver"] as? String ?? ""
    r.outcome = v["outcome"] as? String ?? "in_progress"; r.correctedOutcome = v["correctedOutcome"] as? String
    r.arrivedAt = d(v["arrivedMs"]); r.completedAt = d(v["completedMs"]); r.correctedCompletedAt = d(v["correctedCompletedMs"])
    r.reasonCode = v["reasonCode"] as? String; r.reasonText = v["reasonText"] as? String; r.flagged = v["flagged"] as? Bool
    return r
}
out["runRow"] = (fx["runRow"] as! [[String: Any]]).map { r -> [String: Any] in
    let row = RouteMemoryCore.runRow(startedAt: d(r["startMs"])!, endedAt: d(r["endMs"]), visits: (r["visits"] as! [[String: Any]]).map(visit), now: d(r["nowMs"])!)
    return ["completed": row.stopsCompleted, "skipped": row.stopsSkipped, "total": row.totalTimeSec as Any? ?? NSNull(), "avg": row.avgPerStopSec as Any? ?? NSNull()]
}
let csv = fx["csv"] as! [String: Any]
out["csv"] = RouteMemoryCore.buildRunCsv((csv["rows"] as! [[String: Any]]).map(visit), tz: csv["tz"] as! String, now: d(csv["nowMs"])!)

let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
