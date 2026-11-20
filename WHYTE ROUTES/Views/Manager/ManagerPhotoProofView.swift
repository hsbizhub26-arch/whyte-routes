import SwiftUI
import AVKit
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
        /// Upload time (server).
        let timestamp: Date?
        /// B2: when the photo was actually taken. Nil on older photos.
        let capturedAt: Date?
        let hasGPS: Bool
        let gpsFixAgeSeconds: Int?
        let fromLibrary: Bool
        /// B7: a video clip rather than a photo.
        let isVideo: Bool

        /// What a dispute should be judged on.
        var takenAt: Date? { capturedAt ?? timestamp }
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
                            ForEach(notes(for: photo), id: \.self) { note in
                                Text(note).font(.caption).foregroundColor(.secondary)
                            }
                            if photo.isVideo, let url = URL(string: photo.url) {
                                VideoPlayer(player: AVPlayer(url: url))
                                    .frame(height: 240)
                                    .cornerRadius(12)
                            } else {
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
        case "arrival":    name = "Arrival"
        case "video":      name = "Video"
        case "completion": name = "Completed"
        default:           name = photo.type.capitalized
        }
        guard let stamp = photo.takenAt else { return name }
        return "\(name) · \(stamp.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Facts that matter in a dispute, stated plainly.
    private func notes(for photo: ProofPhoto) -> [String] {
        var out: [String] = []
        if photo.capturedAt != nil {
            out.append("Time is when the photo was taken.")
            if let taken = photo.capturedAt, let uploaded = photo.timestamp,
               uploaded.timeIntervalSince(taken) > 600 {
                out.append("Uploaded later (\(uploaded.formatted(date: .omitted, time: .shortened))) - the phone had no signal.")
            }
        } else if photo.timestamp != nil {
            out.append("Older photo: time shown is when it uploaded.")
        }
        if photo.hasGPS {
            if let age = photo.gpsFixAgeSeconds, age > 120 {
                out.append("Phone location saved, but the GPS fix was \(age / 60) min old.")
            } else {
                out.append("Phone location saved with the photo.")
            }
        }
        if photo.fromLibrary { out.append("Chosen from the photo library, not taken with the camera.") }
        return out
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
                    let gps = data["gpsAtCapture"] as? [String: Any]
                    return ProofPhoto(
                        id: doc.documentID,
                        url: url,
                        type: data["type"] as? String ?? "photo",
                        timestamp: (data["timestamp"] as? Timestamp)?.dateValue(),
                        capturedAt: (data["capturedAt"] as? Timestamp)?.dateValue(),
                        hasGPS: gps != nil,
                        gpsFixAgeSeconds: gps?["fixAgeSeconds"] as? Int,
                        fromLibrary: (data["source"] as? String) == "library",
                        isVideo: (data["mediaType"] as? String) == "video"
                    )
                }
                .sorted { ($0.takenAt ?? .distantPast) < ($1.takenAt ?? .distantPast) }
                isLoading = false
            }
    }
}
