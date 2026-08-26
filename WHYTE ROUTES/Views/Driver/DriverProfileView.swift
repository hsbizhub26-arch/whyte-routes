import SwiftUI
import FirebaseAuth

struct DriverProfileView: View {

    @ObservedObject private var session = DriverSession.shared
    @State private var showReportIssue = false

    @StateObject private var photoUploader = PhotoUploader()
    private let driverRepo: DriverRepository = FirestoreDriverRepository()
    @State private var showCamera = false
    @State private var licenseImage: UIImage?
    @State private var isUploadingLicense = false
    @State private var licenseError: String?

    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            VStack(spacing: 24) {

                // MARK: - Header
                VStack(spacing: 6) {
                    Text("Profile")
                        .foregroundColor(Color("WRThemeGold"))
                        .font(.largeTitle.bold())

                    Text("Driver Information")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.subheadline)
                }

                Divider().overlay(Color("WRThemeGold")).padding(.horizontal)

                // MARK: - Driver Info
                if let driver = session.driver {

                    VStack(spacing: 16) {

                        infoRow(title: "Name", value: driver.name)
                        infoRow(title: "Vehicle", value: driver.vehicle)
                        infoRow(title: "Phone", value: driver.phone ?? "N/A")

                        if let updated = driver.lastUpdated {
                            infoRow(
                                title: "Last Updated",
                                value: TimestampFormatter.shared.asTimeAgo(updated)
                            )
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.25))
                    .cornerRadius(16)

                    licenseSection(driverId: driver.id)
                }

                Spacer()

                // MARK: - Report Issue (the actual point of a beta day -
                // capture "where is that button?" the moment it happens)
                Button {
                    showReportIssue = true
                } label: {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                        .foregroundColor(Color("WRThemeGold"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.black.opacity(0.25))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color("WRThemeGold"), lineWidth: 1)
                        )
                }
                .padding(.horizontal)

                // MARK: - Logout
                Button(role: .destructive) {
                    // Signing out of Firebase is what actually matters -
                    // AuthSession's listener reacts to that and clears
                    // DriverSession/CompanySession/LocationService itself
                    // (see AuthSession.listenForAuthChanges). Calling
                    // session.logout() here directly without signing out
                    // of Firebase would leave the account still
                    // authenticated while the driver's own data vanished
                    // underneath it - that was the actual logout bug.
                    try? Auth.auth().signOut()
                } label: {
                    Text("Log Out")
                        .foregroundColor(.white)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.7))
                        .cornerRadius(16)
                }
                .padding(.horizontal)

                Spacer(minLength: 30)
            }
            .padding()
        }
        .sheet(isPresented: $showReportIssue) {
            ReportIssueView(
                reporterName: session.driver?.name ?? "Driver",
                reporterRole: "driver",
                routeId: session.assignedRoute?.id
            )
        }
        .sheet(isPresented: $showCamera) {
            ImagePicker(image: $licenseImage) { picked in
                Task { await uploadLicense(picked) }
            }
        }
        .task {
            await loadExistingLicensePhoto()
        }
    }

    // MARK: - Reusable Info Row
    func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(Color("WRThemeGold"))
                .font(.headline)

            Spacer()

            Text(value)
                .foregroundColor(.white)
                .font(.body)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Driver's License
    // Owner/manager-visible, other drivers never see this (see
    // storage.rules and Driver.licensePhotoPath). Uploading replaces
    // whatever was there before - a driver only ever has one current
    // license photo on file.
    @ViewBuilder
    private func licenseSection(driverId: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Driver's License")
                .foregroundColor(Color("WRThemeGold"))
                .font(.headline)

            Text("Visible only to you and your company's owner/manager - never to other drivers.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))

            if let licenseImage {
                Image(uiImage: licenseImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .cornerRadius(12)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.3))
                    .frame(height: 120)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "person.text.rectangle")
                                .font(.title2)
                            Text("No license photo on file")
                                .font(.caption)
                        }
                        .foregroundColor(.white.opacity(0.5))
                    )
            }

            if isUploadingLicense {
                ProgressView().tint(Color("WRThemeGold"))
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    showCamera = true
                } label: {
                    Label(licenseImage == nil ? "Take Photo" : "Retake Photo", systemImage: "camera.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color("WRThemeGold"))
                        .cornerRadius(10)
                }
            }

            if let licenseError {
                Text(licenseError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color.black.opacity(0.25))
        .cornerRadius(16)
    }

    private func loadExistingLicensePhoto() async {
        guard let path = session.driver?.licensePhotoPath else { return }
        do {
            licenseImage = try await photoUploader.fetchLicensePhoto(path: path)
        } catch {
            // Not an error worth surfacing to the driver - just means
            // the "no photo on file" state stays showing, same as if
            // none had ever been uploaded.
        }
    }

    private func uploadLicense(_ image: UIImage) async {
        guard let driverId = session.driver?.id,
              let companyId = CompanySession.shared.currentCompanyId else {
            licenseError = "Couldn't upload - try again in a moment."
            return
        }

        isUploadingLicense = true
        licenseError = nil

        do {
            let path = try await photoUploader.uploadLicensePhoto(image: image, companyId: companyId, driverId: driverId)
            driverRepo.updateLicensePhotoPath(driverId: driverId, path: path) { success in
                Task { @MainActor in
                    if success {
                        session.driver?.licensePhotoPath = path
                    } else {
                        licenseError = "Photo uploaded but couldn't save to your profile - try again."
                    }
                }
            }
        } catch {
            licenseError = "Upload failed: \(error.localizedDescription)"
        }

        isUploadingLicense = false
    }
}

