import SwiftUI
import Combine
import FirebaseAuth

@MainActor
final class ManageEmployeesViewModel: ObservableObject {

    @Published var pendingInvites: [Invite] = []
    @Published var contactMethod: String = "email" // "email" | "phone"
    @Published var contactValue: String = ""
    @Published var role: String = "driver" // "driver" | "manager"
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private let repo = InviteRepository()

    func startListening() {
        guard let companyId = CompanySession.shared.currentCompanyId else { return }
        repo.listenToPendingInvites(companyId: companyId) { [weak self] invites in
            self?.pendingInvites = invites.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func sendInvite() {
        guard let companyId = CompanySession.shared.currentCompanyId,
              let companyName = CompanySession.shared.currentCompany?.name,
              let ownerUID = AuthSession.shared.user?.uid
        else {
            errorMessage = "No company loaded yet - try again in a moment."
            return
        }

        guard !contactValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Enter a \(contactMethod == "email" ? "email address" : "phone number")."
            return
        }

        errorMessage = nil
        successMessage = nil
        isSending = true

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
                    self.successMessage = "Invite sent."
                    self.contactValue = ""
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelInvite(_ invite: Invite) {
        repo.cancelInvite(id: invite.id)
    }
}

struct ManageEmployeesView: View {

    @StateObject private var vm = ManageEmployeesViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                WRTheme.gradient.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        inviteForm
                        pendingInvitesSection
                    }
                    .padding()
                }
            }
            .navigationTitle("Team")
            .onAppear { vm.startListening() }
        }
    }

    private var inviteForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Invite Someone")
                .font(.headline)
                .foregroundColor(WRTheme.gold)

            Picker("Contact via", selection: $vm.contactMethod) {
                Text("Email").tag("email")
                Text("Phone").tag("phone")
            }
            .pickerStyle(.segmented)

            TextField(vm.contactMethod == "email" ? "Email address" : "Phone number", text: $vm.contactValue)
                .keyboardType(vm.contactMethod == "email" ? .emailAddress : .phonePad)
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
