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
    @State private var isEditingName = false
    @State private var nameInput = ""
    @State private var isSavingName = false
    @State private var isEditingVehicle = false
    @State private var vehicleInput = ""
    @State private var isSavingVehicle = false

    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            // SCROLLVIEW, not a bare VStack.
            //
            // This column is about 1040pt of content - header, info
            // card, licence section, three buttons and two captions -
            // in roughly 710pt of usable height on an iPhone inside the
            // tab bar. With nowhere to scroll, SwiftUI squeezed it: the
            // "Profile" title rode up underneath the status bar and
            // collided with the clock, and the caption at the bottom
            // got clipped mid-sentence. It read as broken because it
            // was overflowing, not because the header was misplaced.
            ScrollView {
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

                        editableNameRow(driver: driver)
                        editableVehicleRow(driver: driver)
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

                // MARK: - Delete Account
                // Required by App Store Guideline 5.1.1(v) for any app
                // that creates accounts, and this is the only screen a
                // driver has that could host it - their tabs are
                // Dashboard / Route / Profile, with no Settings. Until
                // this existed, deletion lived solely in SettingsView,
                // which only owners and managers ever see.
                DeleteAccountButton(standalone: true)
                    .padding(.horizontal)
                    .padding(.top, 4)

                Text("Deleting your account removes your driver profile, your licence photo, and your login. It cannot be undone.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer(minLength: 30)
            }
            .padding()
            }
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

    // MARK: - Editable Name Row
    // The actual fix for "welcome, someone@gmail.com" - a driver
    // record's name previously had no UI anywhere that let a driver
    // set their own, so it silently stayed whatever placeholder
    // (often the account email) it was created with. Saves through
    // the same FirestoreDriverRepository.updateDriverName an owner's
    // ManageEmployeesView already used - now the driver has that path
    // too, on their own record only.
    @ViewBuilder
    private func editableNameRow(driver: Driver) -> some View {
        if isEditingName {
            HStack {
                Text("Name")
                    .foregroundColor(Color("WRThemeGold"))
                    .font(.headline)

                TextField("Your name", text: $nameInput)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { saveName(driverId: driver.id) }

                Button {
                    saveName(driverId: driver.id)
                } label: {
                    if isSavingName {
                        ProgressView().tint(Color("WRThemeGold"))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color("WRThemeGold"))
                    }
                }
                .disabled(isSavingName || nameInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                Text("Name")
                    .foregroundColor(Color("WRThemeGold"))
                    .font(.headline)

                Spacer()

                Text(driver.name)
                    .foregroundColor(.white)
                    .font(.body)

                Button {
                    nameInput = driver.name
                    isEditingName = true
                } label: {
                    Image(systemName: "pencil.circle")
                        .foregroundColor(Color("WRThemeGold"))
                }
            }
            .padding(.vertical, 4)
        }
    }

    // Mirrors editableNameRow. The Vehicle row used to be read-only
    // with nothing anywhere in the app that could write it, so it
    // showed every driver a blank field forever.
    @ViewBuilder
    private func editableVehicleRow(driver: Driver) -> some View {
        if isEditingVehicle {
            HStack {
                Text("Vehicle")
                    .foregroundColor(Color("WRThemeGold"))
                    .font(.headline)

                TextField("e.g. Truck 2, F-250", text: $vehicleInput)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { saveVehicle(driverId: driver.id) }

                Button {
                    saveVehicle(driverId: driver.id)
                } label: {
                    if isSavingVehicle {
                        ProgressView().tint(Color("WRThemeGold"))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color("WRThemeGold"))
                    }
                }
                .disabled(isSavingVehicle)
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                Text("Vehicle")
                    .foregroundColor(Color("WRThemeGold"))
                    .font(.headline)
                Spacer()
                Text(driver.vehicle.isEmpty ? "Not set" : driver.vehicle)
                    .foregroundColor(driver.vehicle.isEmpty ? .white.opacity(0.4) : .white)
                Button {
                    vehicleInput = driver.vehicle
                    isEditingVehicle = true
                } label: {
                    Image(systemName: "pencil.circle")
                        .foregroundColor(Color("WRThemeGold"))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func saveVehicle(driverId: String) {
        let trimmed = vehicleInput.trimmingCharacters(in: .whitespaces)
        isSavingVehicle = true
        driverRepo.updateDriverVehicle(driverId: driverId, vehicle: trimmed) { success in
            Task { @MainActor in
                isSavingVehicle = false
                if success {
                    session.driver?.vehicle = trimmed
                    isEditingVehicle = false
                }
            }
        }
    }

    private func saveName(driverId: String) {
        let trimmed = nameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSavingName = true
        driverRepo.updateDriverName(driverId: driverId, name: trimmed) { success in
            Task { @MainActor in
                isSavingName = false
                if success {
                    session.driver?.name = trimmed
                    isEditingName = false
                }
            }
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

