import SwiftUI
import MapKit

// Reusable address field with live suggestions as you type, backed
// by AddressSearchService (MapKit, no API key). Used anywhere an
// address is entered - route stops, customers - so every one of
// them ends up with real coordinates instead of a placeholder zero.
struct AddressAutocompleteField: View {

    @Binding var address: String
    var placeholder: String = "Address"
    var onResolved: (String, Double, Double) -> Void

    @StateObject private var search = AddressSearchService()
    @State private var showSuggestions = false
    /// Set right before select() writes the resolved address back into
    /// the field, so that programmatic write doesn't re-trigger the
    /// search and pop a fresh suggestion list under the finger that
    /// just dismissed it.
    @State private var suppressNextChange = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $address)
                .onChange(of: address) { _, newValue in
                    if suppressNextChange {
                        suppressNextChange = false
                        return
                    }
                    search.updateQuery(newValue)
                    showSuggestions = !newValue.isEmpty
                }

            if showSuggestions && !search.results.isEmpty {
                let visible = Array(search.results.prefix(5).enumerated())
                VStack(alignment: .leading, spacing: 0) {
                    // Identity is the COMPLETION, not the row position.
                    // The completer streams new results while a finger
                    // is mid-tap; with positional ids SwiftUI swaps new
                    // data into "the same" row and the tap fires on
                    // whatever address just moved under it.
                    ForEach(visible, id: \.element) { index, completion in
                        Button {
                            select(completion)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(completion.title)
                                    .foregroundColor(.primary)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if index != visible.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        // Dismiss synchronously, BEFORE the async resolve - leaving the
        // list up while awaiting meant late completer results kept
        // repainting it, and a second tap (or the tail of this one)
        // could land on a different address.
        showSuggestions = false
        search.updateQuery("")
        Task {
            if let resolved = await search.resolve(completion) {
                suppressNextChange = true
                address = resolved.address
                onResolved(resolved.address, resolved.latitude, resolved.longitude)
            }
        }
    }
}
