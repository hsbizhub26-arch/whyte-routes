import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFunctions

@MainActor
final class ManageEmployeesViewModel: ObservableObject {

    @Published var pendingInvites: [Invite] = []
    @Published var activeDrivers: [Driver] = []
    @Published var contactMethod: String = "email" // "email" | "phone"
    @Published var contactValue: String = ""
    @Published var role: String = "driver" // "driver" | "manager"
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private let repo = InviteRepository()
    private let driverRepo: DriverRepository = FirestoreDriverRepository()

    func startListening() {
        guard let companyId = CompanySession.shared.currentCompanyId else { return }
        repo.listenToPendingInvites(companyId: companyId) { [weak self] invites in
            self?.pendingInvites = invites.sorted { $0.createdAt > $1.createdAt }
        }
        driverRepo.listenToDrivers { [weak self] drivers in
            // Revoked people are tombstones, not teammates. Filtered out
            // of Active Team and out of every assignment picker - but
            // deliberately NOT out of Driver Reports, so an owner can
            // still pull a former employee's hours for payroll.
            self?.activeDrivers = drivers
                .filter { !$0.isRevoked }
                .sorted { $0.name < $1.name }
        }
    }

    func renameDriver(_ driver: Driver, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        driverRepo.updateDriverName(driverId: driver.id, name: trimmed, completion: nil)
    }

    /// Set when an invite is blocked by the plan's driver ceiling, so the
    /// view can present the paywall instead of an inline error.
    @Published var hitDriverLimit = false

    func sendInvite() {
        guard let companyId = CompanySession.shared.currentCompanyId,
              let companyName = CompanySession.shared.currentCompany?.name,
              let ownerUID = AuthSession.shared.user?.uid
        else {
            errorMessage = "No company loaded yet - try again in a moment."
            return
        }

        // The driver ceiling had NO enforcement either - canAddDriver()
        // was dead code. A free company could invite an entire crew and
        // dispatch it indefinitely. Pending invites count toward the
        // limit as well as active drivers, or the ceiling is trivially
        // walked around by queueing invitations.
        let access = FeatureAccessManager.shared
        let crewSize = activeDrivers.count + pendingInvites.count
        guard access.canAddDriver(currentCount: crewSize) else {
            hitDriverLimit = true
            return
        }

        guard !contactValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Enter a \(contactMethod == "email" ? "email address" : "phone number")."
            return
        }

        errorMessage = nil
        successMessage = nil
        isSending = true

        // Captured before the field is cleared, so the confirmation can
        // name the address the invitee has to sign up with.
        let invitedValue = contactValue.trimmingCharacters(in: .whitespaces)

        repo.createInvite(
            companyId: companyId,
            companyName: companyName,
            contactMethod: contactMethod,
            contactValue: contactValue,
            role: role,
            invitedByUID: ownerUID
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isSending = false
                switch result {
                case .success:
                    // NOT "Invite sent." Nothing is sent: creating an
                    // invite writes a Firestore document and no email,
                    // text or link leaves the system - there is no
                    // invite-delivery function anywhere. An owner who
                    // read "Invite sent" reasonably waited for a driver
                    // who was never contacted.
                    //
                    // The document is genuinely all that's needed: the
                    // person downloads the app, signs up with that exact
                    // address, and AuthSession matches the pending
                    // invite on their verified email. So say that, and
                    // name the address, instead of implying we did the
                    // contacting.
                    let address = invitedValue
                    self.successMessage = "Invite created for \(address). Ask them to download WHYTE ROUTES and sign up using that exact email address - they'll join your company automatically."
                    self.contactValue = ""
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Offboards a teammate through the revokeEmployee Cloud Function.
    ///
    /// This CANNOT be done from the client: firestore.rules freezes
    /// companyId on the owner-manages-employee branch and blocks
    /// deleting another user's document, so the one field that gates
    /// access is the one field an owner may not touch. The function
    /// runs on the Admin SDK and closes the open shift, hands the route
    /// back to Unassigned and supersedes live customer links before
    /// cutting access - in that order, because afterwards nobody can
    /// close that shift.
    @discardableResult
    func revoke(_ driver: Driver) async -> Bool {
        errorMessage = nil
        successMessage = nil
        do {
            let result = try await Functions.functions()
                .httpsCallable("revokeEmployee")
                .call(["targetUid": driver.id])
            let data = result.data as? [String: Any]
            let routes = data?["routesReleased"] as? Int ?? 0
            let shifts = data?["shiftsClosed"] as? Int ?? 0
            var detail = "\(driver.name) no longer has access."
            if routes > 0 { detail += " \(routes) route\(routes == 1 ? "" : "s") returned to Unassigned." }
            if shifts > 0 { detail += " Open shift closed and hours kept." }
            successMessage = detail
            return true
        } catch {
            errorMessage = "Couldn't remove \(driver.name): \(error.localizedDescription)"
            return false
        }
    }

    func cancelInvite(_ invite: Invite) {
        repo.cancelInvite(id: invite.id)
    }
}

struct ManageEmployeesView: View {

    @StateObject private var vm = ManageEmployeesViewModel()
    @State private var renamingDriver: Driver?
    @State private var renameText = ""
    @State private var licenseViewerDriver: Driver?
    /// Offboarding is irreversible for the current season, so it is
    /// confirmed with the real consequences named rather than a generic
    /// "are you sure".
    @State private var pendingRemoval: Driver?
    @State private var isRemoving = false

    var body: some View {
        NavigationStack {
            ZStack {
                WRTheme.gradient.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        inviteForm
                        activeTeamSection
                        pendingInvitesSection
                    }
                    .padding()
                    .readableContentWidth()
                }
            }
            .navigationTitle("Team")
            .onAppear { vm.startListening() }
            .sheet(isPresented: $vm.hitDriverLimit) {
                UpgradeRequiredView(
                    featureName: "More than \(FeatureAccessManager.shared.driverLimit ?? 1) driver",
                    requiredTier: .premium
                )
            }
            .alert("Driver Name", isPresented: Binding(
                get: { renamingDriver != nil },
                set: { if !$0 { renamingDriver = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingDriver = nil }
                Button("Save") {
                    if let driver = renamingDriver {
                        vm.renameDriver(driver, to: renameText)
                    }
                    renamingDriver = nil
                }
            } message: {
                Text("Shown on the live fleet map and everywhere else this driver appears.")
            }
            .sheet(item: $licenseViewerDriver) { driver in
                DriverLicenseViewerSheet(driver: driver)
            }
            .confirmationDialog(
                pendingRemoval.map { "Remove \($0.name)?" } ?? "Remove",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove from company", role: .destructive) {
                    guard let driver = pendingRemoval else { return }
                    pendingRemoval = nil
                    isRemoving = true
                    Task { await vm.revoke(driver); isRemoving = false }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("They lose access immediately. Their logged hours are kept for payroll, any open shift is closed, and any route assigned to them returns to Unassigned.")
            }
        }
    }

    private var activeTeamSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Team")
                .font(.headline)
                .foregroundColor(WRTheme.gold)

            if vm.activeDrivers.isEmpty {
                Text("No drivers yet - send an invite below.")
                    .foregroundColor(.white.opacity(0.6))
                    .font(.subheadline)
            } else {
                ForEach(vm.activeDrivers) { driver in
                    HStack {
                        Button {
                            renameText = driver.name
                            renamingDriver = driver
                        } label: {
                            HStack {
                                Circle()
                                    .fill(driver.color)
                                    .frame(width: 10, height: 10)
                                Text(driver.name)
                                    .foregroundColor(.white)
                                Spacer()
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }

                        Button {
                            licenseViewerDriver = driver
                        } label: {
                            Image(systemName: "person.text.rectangle")
                                .font(.subheadline)
                                .foregroundColor(WRTheme.gold)
                        }
                        .padding(.leading, 4)

                        Button(role: .destructive) {
                            pendingRemoval = driver
                        } label: {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                        .padding(.leading, 4)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                }
            }
        }
    }

    private var inviteForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Invite Someone")
                .font(.headline)
                .foregroundColor(WRTheme.gold)

            // The Phone option is deliberately not offered. Accepting an
            // invite requires a matching verified contact on the
            // accepting account's own auth token, and for phone that
            // means a phone_number claim - which only phone
            // authentication produces, and this app has none (no
            // PhoneAuthProvider anywhere). A phone invite could
            // therefore be created and displayed as pending, and then
            // never be acceptable by anybody, forever.
            //
            // The rules and AuthSession.findUsableInvite already handle
            // phone correctly for whenever phone auth does land; this is
            // only the UI declining to offer a door with no room behind
            // it.
            TextField("Email address", text: $vm.contactValue)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(Color.gray.opacity(0.4))
                .cornerRadius(12)
                .foregroundColor(.white)

            Picker("Role", selection: $vm.role) {
                Text("Driver").tag("driver")
                Text("Manager").tag("manager")
            }
            .pickerStyle(.segmented)

            if let error = vm.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
            if let success = vm.successMessage {
                Text(success)
                    .font(.footnote)
                    .foregroundColor(.green)
            }

            Button {
                vm.sendInvite()
            } label: {
                Text(vm.isSending ? "Sending…" : "Send Invite")
                    .fontWeight(.bold)
            }
            .buttonStyle(GoldButtonStyle())
            .disabled(vm.isSending)
        }
        .padding()
        .background(WRTheme.softBlack)
        .cornerRadius(14)
    }

    private var pendingInvitesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending Invites")
                .font(.headline)
                .foregroundColor(WRTheme.gold)

            if vm.pendingInvites.isEmpty {
                Text("No pending invites.")
                    .foregroundColor(.white.opacity(0.6))
                    .font(.subheadline)
            } else {
                ForEach(vm.pendingInvites) { invite in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.id)
                                .foregroundColor(.white)
                            Text("\(invite.role.capitalized) · \(invite.isExpired ? "Expired" : "Pending")")
                                .font(.caption)
                                .foregroundColor(invite.isExpired ? .red : .white.opacity(0.6))
                        }
                        Spacer()
                        Button("Cancel") {
                            vm.cancelInvite(invite)
                        }
                        .font(.footnote)
                        .foregroundColor(.red)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                }
            }
        }
    }
}

// Owner/manager view of a single driver's license photo - fetched
// through the authenticated Storage SDK call (respects storage.rules),
// never via a shareable download URL. See Driver.licensePhotoPath for
// why that distinction matters: a download URL would let anyone who
// got hold of it view the photo regardless of who they are, which is
// exactly what this feature is supposed to prevent for other drivers.
private struct DriverLicenseViewerSheet: View {

    let driver: Driver

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                WRTheme.gradient.ignoresSafeArea()

                if isLoading {
                    ProgressView().tint(WRTheme.gold)
                } else if let image {
                    ScrollView {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
                            .padding()
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "person.text.rectangle")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.4))
                        Text(errorMessage ?? "No license photo on file for \(driver.name).")
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("\(driver.name)'s License")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            guard let path = driver.licensePhotoPath else {
                isLoading = false
                return
            }
            do {
                image = try await PhotoUploader().fetchLicensePhoto(path: path)
            } catch {
                errorMessage = "Couldn't load the photo - check your connection."
            }
            isLoading = false
        }
    }
}
