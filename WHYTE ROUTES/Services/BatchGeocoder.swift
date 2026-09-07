import Foundation
import CoreLocation

/// Turns raw address lines into real coordinates using CoreLocation,
/// on-device and free.
///
/// Deliberately NOT AddressSearchService: that resolves an
/// MKLocalSearchCompletion the user has already tapped, so it cannot
/// take a bare CSV line. This is the missing half.
///
/// Serialized with spacing on purpose. CLGeocoder is rate-limited per
/// process and answers a burst of parallel requests with
/// kCLErrorDomain 2 for most of them - which would look exactly like
/// "half my addresses are bad" to a dispatcher whose file was fine.
actor BatchGeocoder {

    struct Resolved {
        let index: Int
        let coordinate: CLLocationCoordinate2D?
        let normalizedAddress: String?
        let failureReason: String?
    }

    /// Apple's documented ceiling is roughly one request per second.
    private static let spacing: Duration = .milliseconds(1200)

    private let geocoder = CLGeocoder()

    /// - Parameter region: biases ambiguous lines ("12 Main St") toward
    ///   where this company actually works, built by the caller from
    ///   existing customer coordinates.
    func resolve(
        addresses: [String],
        near region: CLCircularRegion?,
        progress: @Sendable (Int, Int) -> Void
    ) async -> [Resolved] {
        var out: [Resolved] = []
        out.reserveCapacity(addresses.count)

        for (index, raw) in addresses.enumerated() {
            let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            progress(index, addresses.count)

            guard !address.isEmpty else {
                out.append(Resolved(index: index, coordinate: nil,
                                    normalizedAddress: nil,
                                    failureReason: "Blank address"))
                continue
            }

            do {
                let marks = try await geocoder.geocodeAddressString(address, in: region)
                if let best = marks.first, let loc = best.location {
                    out.append(Resolved(index: index,
                                        coordinate: loc.coordinate,
                                        normalizedAddress: Self.formatted(best) ?? address,
                                        failureReason: nil))
                } else {
                    out.append(Resolved(index: index, coordinate: nil,
                                        normalizedAddress: nil,
                                        failureReason: "No match found"))
                }
            } catch {
                out.append(Resolved(index: index, coordinate: nil,
                                    normalizedAddress: nil,
                                    failureReason: Self.readable(error)))
            }

            if index < addresses.count - 1 {
                try? await Task.sleep(for: Self.spacing)
            }
        }
        progress(addresses.count, addresses.count)
        return out
    }

    private static func formatted(_ mark: CLPlacemark) -> String? {
        let parts = [
            [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " "),
            mark.locality,
            mark.administrativeArea,
            mark.country,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Rate-limiting is the one failure a dispatcher can actually act
    /// on, so it is named rather than shown as a raw error code.
    private static func readable(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == kCLErrorDomain, ns.code == CLError.network.rawValue {
            return "Rate limited - retry this row"
        }
        if ns.domain == kCLErrorDomain, ns.code == CLError.geocodeFoundNoResult.rawValue {
            return "No match found"
        }
        return ns.localizedDescription
    }
}
