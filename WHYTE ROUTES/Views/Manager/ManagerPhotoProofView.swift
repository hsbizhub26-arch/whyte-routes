import SwiftUI
import FirebaseFirestore

/// Owner/manager-side viewer for the proof-of-work photos a driver
/// uploads from DriverStopView. Opened from the stop's row in
/// EditRouteView.
struct ManagerPhotoProofView: View {

    let companyId: String
    let routeId: String
    let stopId: String

    struct ProofPhoto: Identifiable {
        let id: String
        let url: String
        let type: String
        let timestamp: Date?
    }

    @State private var photos: [ProofPhoto] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    ProgressView("Loading photos…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundColor(.red)
                } else if photos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "camera")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No photos for this stop yet.")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(photos) { photo in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(label(for: photo))
                                .font(.headline)
                            AsyncImage(url: URL(string: photo.url)) { image in
                                image.resizable().scaledToFit().cornerRadius(12)
                            } placeholder: {
                                ProgressView()
                                    .frame(height: 180)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .padding()
            .readableContentWidth()
        }
        .navigationTitle("Photo Proof")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadPhotos)
    }

    // Every type the app writes is labelled and shown. The previous
    // version rendered only "before" and "after" and silently dropped
    // "completion" - which is the ONLY type DriverStopView uploads, so
    // in practice it showed nothing at all.
    private func label(for photo: ProofPhoto) -> String {
        let name: String
        switch photo.type {
        case "before":     name = "Before"
        case "after":      name = "After"
        case "completion": name = "Completed"
        default:           name = photo.type.capitalized
        }
        guard let stamp = photo.timestamp else { return name }
        return "\(name) · \(stamp.formatted(date: .abbreviated, time: .shortened))"
    }

    private func loadPhotos() {
        // PhotoUploader writes to
        //   companies/{companyId}/routes/{routeId}/stops/{stopId}/photos
        // This used to read a TOP-LEVEL "stops" collection that does not
        // exist anywhere in the schema, so it returned nothing no matter
        // how many photos a driver had uploaded.
        Firestore.firestore()
            .collection("companies").document(companyId)
            .collection("routes").document(routeId)
            .collection("stops").document(stopId)
            .collection("photos")
            .order(by: "timestamp")
            .getDocuments { snapshot, error in
                if let error {
                    errorMessage = "Couldn't load photos: \(error.localizedDescription)"
                    isLoading = false
                    return
                }

                // Listed, not collapsed into a [type: url] dictionary -
                // that kept only the LAST photo of each type and threw
                // the rest away.
                photos = (snapshot?.documents ?? []).compactMap { doc in
                    let data = doc.data()
                    guard let url = data["url"] as? String else { return nil }
                    return ProofPhoto(
                        id: doc.documentID,
                        url: url,
                        type: data["type"] as? String ?? "photo",
                        timestamp: (data["timestamp"] as? Timestamp)?.dateValue()
                    )
                }
                isLoading = false
            }
    }
}
