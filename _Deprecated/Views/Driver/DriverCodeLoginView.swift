import SwiftUI

@MainActor
final class DriverCodeLoginViewModel: ObservableObject {

    @Published var code: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let repo = DriverRepository()

    // MARK: - Validate Code
    func login() async -> Bool {
        guard code.count >= 3 else {
            errorMessage = "Enter your driver code"
            return false
        }

        isLoading = true
        defer { isLoading = false }

        let result = await fetchDriverByCode()

        switch result {
        case .success(let driver):
            DriverSession.shared.login(with: driver)
            return true
        case .failure:
            errorMessage = "Invalid code"
            return false
        }
    }

    // MARK: - Fetch Driver by Code
    private func fetchDriverByCode() async -> Result<Driver, Error> {
        do {
            let driversResult = try await withCheckedThrowingContinuation { continuation in
                repo.fetchDrivers { result in
                    switch result {
                    case .success(let drivers):
                        continuation.resume(returning: drivers)
                    case .failure(let err):
                        continuation.resume(throwing: err)
                    }
                }
            }

            if let match = driversResult.first(where: { $0.phone == code || $0.fleetId == code }) {
                return .success(match)
            }

            return .failure(NSError(domain: "not_found", code: 404))
        } catch {
            return .failure(error)
        }
    }
}

struct DriverCodeLoginView: View {

    @StateObject private var vm = DriverCodeLoginViewModel()
    @State private var goToApp = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                Text("Driver Code Login")
                    .font(.largeTitle.bold())
                    .foregroundColor(Color("WRThemeGold"))
                    .padding(.top, 40)

                Text("Enter your driver code to begin your shift.")
                    .foregroundColor(.gray)

                // MARK: - Code TextField
                TextField("1234", text: $vm.code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color.black.opacity(0.15))
                    .cornerRadius(12)
                    .foregroundColor(.white)
                    .font(.title2.bold())
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color("WRThemeGold"), lineWidth: 1.5)
                    )
                    .padding(.horizontal)

                if let error = vm.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.callout)
                }

                // MARK: - Login Button
                Button {
                    Task {
                        let success = await vm.login()
                        if success { goToApp = true }
                    }
                } label: {
                    if vm.isLoading {
                        ProgressView().tint(Color("WRThemeGold"))
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Text("Login")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.black)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                Spacer()

                // MARK: - Navigation to App
                NavigationLink(destination: DriverTabView(),
                               isActive: $goToApp) {
                    EmptyView()
                }
                .hidden()

            }
            .padding()
            .background(Color("WRBlack").ignoresSafeArea())
        }
    }
}
