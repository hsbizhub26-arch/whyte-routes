import Foundation

struct RouteTemplate: Identifiable, Codable {
    var id: String
    var name: String
    var stops: [Stop]

    init(
        id: String = UUID().uuidString,
        name: String,
        stops: [Stop] = []
    ) {
        self.id = id
        self.name = name
        self.stops = stops
    }
}

// Firestore decode/encode helpers if you plan to store templates online
extension RouteTemplate {

    init?(from dict: [String: Any], id: String) {
        guard let name = dict["name"] as? String else { return nil }

        let stopDicts = dict["stops"] as? [[String: Any]] ?? []
        let stops = stopDicts.compactMap { Stop(from: $0) }

        self.id = id
        self.name = name
        self.stops = stops
    }

    func toDict() -> [String: Any] {
        [
            "name": name,
            "stops": stops.map { $0.toDict() }
        ]
    }
}
