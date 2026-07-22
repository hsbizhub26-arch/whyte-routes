import Foundation
import MapKit
import Combine

// Wraps MapKit's built-in local search completer - no API key, no
// billing account, already part of this app (it's what draws the
// maps). Deliberately not Google Places: that needs its own Google
// Cloud project and a card on file, the exact friction avoided for
// Firebase Storage earlier in this project.
@MainActor
final class AddressSearchService: NSObject, ObservableObject {

    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = .address
        completer.delegate = self
    }

    func updateQuery(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    /// Resolves a tapped suggestion into a full address string plus
    /// real coordinates - this is what turns a stop/customer address
    /// from plain text into an actual routable location.
    func resolve(_ completion: MKLocalSearchCompletion) async -> (address: String, latitude: Double, longitude: Double)? {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)

        do {
            let response = try await search.start()
            guard let item = response.mapItems.first else { return nil }
            let coordinate = item.placemark.coordinate
            let address = [completion.title, completion.subtitle]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return (address, coordinate.latitude, coordinate.longitude)
        } catch {
            print("⚠️ AddressSearchService.resolve failed: \(error.localizedDescription)")
            return nil
        }
    }
}

extension AddressSearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.results = completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("⚠️ AddressSearchService completer error: \(error.localizedDescription)")
    }
}
