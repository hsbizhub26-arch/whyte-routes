import SwiftUI
import FirebaseAuth

// Shown instead of OwnerTabView whenever a signed-in "owner" has no
// company yet - either a brand new self-serve signup (see
// AuthSession's "genuinely no invite waiting" branch) or someone who
// started this before and closed the app mid-setup. Deliberately
// minimal per explicit instruction: one field, one plan choice, one
// button - no multi-step wizard. More advanced onboarding can come
// later; this just has to get a new business from "just signed up"
// to "has a working company" without a dead end.
struct CreateCompanyView: View {

    private enum StartingPlan: String, CaseIterable, Identifiable {
        case starter = "Starter"
        case premium = "Premium"
        case premiumPlus = "Premium Plus"
        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .starter: return "Free - up to 10 customers"
            // Keep in step with SubscriptionTierView.Tier.features -
            // this is the same promise, made on a different screen.
            // "proof of work" was dropped from both: the capture button
            // has no call site, so the feature is unreachable on every tier.
            case .premium: return "Customer texts & tracking, live fleet map, route optimization"
            case .premiumPlus: return "Everything in Premium, plus driver reports & unlimited customers"
            }
        }
    }

    @State private var companyName = ""
    @State private var selectedPlan: StartingPlan = .starter
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showPaywallAfterCreate = false

    private let companyRepo = CompanyRepository()

    var body: some View {
        ZStack {
            WRTheme.gradient.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Company Name")
                            .font(.headline)
                            .foregroundColor(WRTheme.gold)

                        TextField("e.g. DW Landscaping", text: $companyName)
                            .textInputAutocapitalization(.words)
                            .padding()
                            .background(Color.gray.opacity(0.4))
                            .cornerRadius(12)
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Starting Plan")
                            .font(.headline)
                            .foregroundColor(WRTheme.gold)

                        ForEach(StartingPlan.allCases) { plan in
                            planRow(plan)
                        }

                        Text("You'll start on Starter today regardless - picking Premium or Premium Plus just opens checkout right after your company is created. You can always change plans later from Settings.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }

                    Button {
                        Task { await createCompany() }
                    } label: {
                        Text(isSaving ? "Creating…" : "Create Company")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GoldButtonStyle())
                    .disabled(isSaving || companyName.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Sign Out") {
                        try? Auth.auth().signOut()
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)

                    // This screen is where a brand-new signup lands, and
                    // where it STAYS until a company is created - so for
                    // anyone who signs up and changes their mind, it is
                    // the whole app. Offering only Sign Out left them
                    // with an account they could not remove, which is
                    // exactly the case Guideline 5.1.1(v) covers. It is
                    // also the first screen an App Store reviewer sees.
                    DeleteAccountButton(standalone: true)
                        .padding(.top, 8)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showPaywallAfterCreate) {
            SubscriptionTierView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to WHYTE ROUTES")
                .font(.title.bold())
                .foregroundColor(.white)
            Text("Set up your company to get started.")
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.top, 12)
    }

    private func planRow(_ plan: StartingPlan) -> some View {
        Button {
            selectedPlan = plan
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.rawValue)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Text(plan.subtitle)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
                Image(systemName: selectedPlan == plan ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedPlan == plan ? WRTheme.gold : .white.opacity(0.3))
            }
            .padding()
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)
        }
    }

    private func createCompany() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let trimmedName = companyName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        errorMessage = nil

        // Always created as starter regardless of selectedPlan - the
        // Firestore rule for self-serve creation only allows that one
        // safe tier (see firestore.rules v10). A picked paid plan is
        // captured by opening the real paywall right after, never by
        // writing a higher tier directly.
        let company = Company(
            id: "",
            name: trimmedName,
            ownerUID: uid,
            subscriptionTier: "starter",
            subscriptionStatus: "trialing",
            billingRequired: true,
            createdAt: Date()
        )

        guard let created = await companyRepo.create(company) else {
            isSaving = false
            errorMessage = "Couldn't create your company - check your connection and try again."
            return
        }

        await UserPermissionsService.shared.backfillIfMissing(
            uid: uid,
            fields: ["companyId": created.id, "companyRole": "owner"]
        )

        await MainActor.run {
            CompanySession.shared.currentCompanyId = created.id
            CompanySession.shared.currentCompany = created
            isSaving = false

            if selectedPlan != .starter {
                showPaywallAfterCreate = true
            }
        }
    }
}
