import SwiftUI
import Vision

/// B4: photograph a business card, contract or note and pre-fill the
/// Add Customer form. Text is read ON THE PHONE (Apple Vision) - the
/// image is never uploaded or stored. The owner reviews every value
/// before it goes into the form, and the form still validates as usual.
struct ScanContactView: View {
    let onUse: (ScannedContact) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Which picker is open: camera, or an existing photo.
    @State private var pickerSource: UIImagePickerController.SourceType?
    private var showCamera: Binding<Bool> {
        Binding(get: { pickerSource != nil }, set: { if !$0 { pickerSource = nil } })
    }
    @State private var picked: UIImage?
    @State private var isReading = false
    @State private var found: ScannedContact?
    @State private var use = [true, true, true, true]   // name, phone, email, address

    var body: some View {
        NavigationStack {
            Group {
                if isReading {
                    ProgressView("Reading the text…").tint(WRTheme.gold)
                } else if let result = found {
                    if result.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "text.viewfinder").font(.largeTitle).foregroundColor(.secondary)
                            Text("Couldn't find a name, phone, email or address in that photo.")
                                .multilineTextAlignment(.center).foregroundColor(.secondary)
                            Button("Try another photo") { found = nil; picked = nil }
                                .foregroundColor(WRTheme.gold)
                        }
                        .padding()
                    } else {
                        review(result)
                    }
                } else {
                    chooser
                }
            }
            .navigationTitle("Scan to Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .padFullScreenSheet(isPresented: showCamera) {
            ImagePicker(image: $picked, onPicked: { image in read(image) }, sourceType: pickerSource)
                .ignoresSafeArea()
        }
    }

    private var chooser: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 44))
                .foregroundColor(WRTheme.gold)
            Text("Photograph a business card, a signed contract or a note with the customer's details.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            Button {
                pickerSource = .camera
            } label: {
                Label("Take Photo", systemImage: "camera.fill")
                    .bold().frame(maxWidth: .infinity, minHeight: 50)
            }
            .background(WRTheme.gold).foregroundColor(.black).cornerRadius(14)
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button {
                pickerSource = .photoLibrary
            } label: {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    .bold().frame(maxWidth: .infinity, minHeight: 50)
            }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(WRTheme.gold, lineWidth: 1))
            .foregroundColor(WRTheme.gold)
            Text("Read on this phone - the photo isn't uploaded or kept.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(24)
    }

    private func review(_ c: ScannedContact) -> some View {
        Form {
            Section {
                row("Name", c.name, 0)
                row("Phone", c.phone, 1)
                row("Email", c.email, 2)
                row("Address", c.address, 3)
            } header: {
                Text("Found in the photo")
            } footer: {
                Text("Check each one - photos can be misread. You'll still pick the address from the suggestions so it lands on the map. The photo isn't saved.")
            }
            Section {
                Button {
                    var out = ScannedContact()
                    if use[0] { out.name = c.name }
                    if use[1] { out.phone = c.phone }
                    if use[2] { out.email = c.email }
                    if use[3] { out.address = c.address }
                    onUse(out)
                    dismiss()
                } label: {
                    Text("Fill the form").bold().frame(maxWidth: .infinity)
                }
                .foregroundColor(WRTheme.gold)
                Button("Try another photo") { found = nil; picked = nil }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, _ i: Int) -> some View {
        if let value {
            Toggle(isOn: $use[i]) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundColor(.secondary)
                    Text(value)
                }
            }
            .tint(WRTheme.gold)
        }
    }

    private func read(_ image: UIImage) {
        guard let cg = image.cgImage else { found = ScannedContact(); return }
        isReading = true
        pickerSource = nil
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-CA", "fr-CA"]
            request.usesLanguageCorrection = false   // names and numbers, not prose
            try? VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let parsed = ContactTextParser.parse(lines: lines)
            await MainActor.run {
                found = parsed
                use = [true, true, true, true]
                isReading = false
            }
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
