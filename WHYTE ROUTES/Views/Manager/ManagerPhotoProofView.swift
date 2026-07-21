import SwiftUI
import FirebaseFirestore

struct ManagerPhotoProofView: View {

    let stopId: String
    @State private var photos: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                if let before = photos["before"] {
                    VStack {
                        Text("Before Photo")
                        AsyncImage(url: URL(string: before)) { img in
                            img.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView()
                        }
                    }
                }

                if let after = photos["after"] {
                    VStack {
                        Text("After Photo")
                        AsyncImage(url: URL(string: after)) { img in
                            img.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView()
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear(perform: loadPhotos)
    }

    func loadPhotos() {
        let db = Firestore.firestore()
        db.collection("stops").document(stopId).collection("photos")
            .getDocuments { snapshot, error in

                guard let docs = snapshot?.documents else { return }

                var map: [String: String] = [:]

                for doc in docs {
                    let data = doc.data()
                    if let url = data["url"] as? String,
                       let type = data["type"] as? String {
                        map[type] = url
                    }
                }

                photos = map
            }
    }
}
