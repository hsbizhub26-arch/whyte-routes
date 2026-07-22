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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $address)
                .onChange(of: address) { _, newValue in
                    search.updateQuery(newValue)
                    showSuggestions = !newValue.isEmpty
                }

            if showSuggestions && !search.results.isEmpty {
                let visible = Array(search.results.prefix(5).enumerated())
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible, id: \.offset) { index, completion in
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
        Task {
            if let resolved = await search.resolve(completion) {
                address = resolved.address
                onResolved(resolved.address, resolved.latitude, resolved.longitude)
            }
            showSuggestions = false
        }
    }
}
