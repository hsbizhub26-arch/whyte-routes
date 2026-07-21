import SwiftUI
import MapKit
import Combine

@MainActor
final class DriverStopViewModel: ObservableObject {

    @Published var stop: Stop
    @Published var isCompleting = false

    private let routeService = RouteService.shared
    private let session = DriverSession.shared

    init(stop: Stop) {
        self.stop = stop
    }

    var route: Route? { session.assignedRoute }

    // MARK: - MARK STOP COMPLETED
    func markCompleted() {
        guard let route else { return }

        isCompleting = true
        stop.isCompleted = true

        routeService.updateStop(routeId: route.id, stop: stop)
        isCompleting = false
    }
}

struct DriverStopView: View {

    @StateObject private var vm: DriverStopViewModel
    @ObservedObject private var session = DriverSession.shared
    @State private var showPhotoCapture = false
    @State private var proofPhotoURL: String?

    init(stop: Stop) {
        _vm = StateObject(wrappedValue: DriverStopViewModel(stop: stop))
    }

    var body: some View {
        ZStack {
            Color("WRBlack").ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {

                    header
                    mapSection
                    actionButtons
                    smsButton
                    photoProofButton
                    completeButton

                    Spacer(minLength: 40)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showPhotoCapture) {
            if let companyId = CompanySession.shared.currentCompanyId,
               let routeId = vm.route?.id,
               let driverId = session.driver?.id {
                PhotoProofView(
                    companyId: companyId,
                    routeId: routeId,
                    stopId: vm.stop.id,
                    driverId: driverId,
                    type: "completion",
                    onUploaded: { url in
                        proofPhotoURL = url
                        showPhotoCapture = false
                    }
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // GPS tracking itself is tied to the shift lifecycle (see
            // DriverSession.startShift/endShift) - this just tells the
            // already-running tracker what "arrived" means for this stop.
            LocationService.shared.setArrivalTarget(lat: vm.stop.latitude, lng: vm.stop.longitude)
        }
    }
}

extension DriverStopView {

    // MARK: HEADER
    private var header: some View {
        VStack(spacing: 6) {
            Text(vm.stop.customerName ?? "Customer")
                .font(.largeTitle.bold())
                .foregroundColor(Color("WRThemeGold"))

            Text(vm.stop.address)
                .foregroundColor(.white.opacity(0.8))
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 10)
    }

    // MARK: MAP
    @ViewBuilder
    private var mapSection: some View {
        if let coordinate = vm.stop.coordinate {
            Map(coordinateRegion: .constant(
                MKCoordinateRegion(
                    center: coordinate,
                    span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            ))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color("WRThemeGold"), lineWidth: 2)
            )
        }
    }

    // MARK: ACTION BUTTONS
    private var actionButtons: some View {
        VStack(spacing: 16) {
            NavigationButton(coordinate: vm.stop.coordinate)
            TimerPill()
        }
    }

    // MARK: SMS
    private var smsButton: some View {
        Group {
            if let phone = vm.stop.customerPhone {
                SMSButton(title: "Text Customer",
                          phone: phone,
                          link: "https://whyteroutes.app/tracking/\(vm.stop.id)")
            }
        }
    }

    // MARK: PHOTO PROOF (optional - not required to complete, but
    // encouraged for dispute resolution / proof of work)
    private var photoProofButton: some View {
        Button {
            showPhotoCapture = true
        } label: {
            HStack {
                Image(systemName: proofPhotoURL != nil ? "checkmark.circle.fill" : "camera.fill")
                Text(proofPhotoURL != nil ? "Photo Added" : "Add Photo Proof")
            }
            .font(.headline)
            .foregroundColor(proofPhotoURL != nil ? .green : .white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.25))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color("WRThemeGold"), lineWidth: 1)
            )
        }
    }

    // MARK: COMPLETE BUTTON
    private var completeButton: some View {
        Button {
            vm.markCompleted()
        } label: {
            HStack {
                if vm.isCompleting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Mark Completed")
                }
            }
            .font(.headline)
            .foregroundColor(.black)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color("WRThemeGold"))
            .cornerRadius(14)
        }
        .disabled(vm.isCompleting || vm.stop.isCompleted)
        .opacity(vm.stop.isCompleted ? 0.4 : 1)
        .padding(.top, 10)
    }
}

