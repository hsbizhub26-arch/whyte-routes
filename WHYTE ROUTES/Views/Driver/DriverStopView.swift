import SwiftUI
import MapKit

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
        guard let stopId = stop.id else { return }

        isCompleting = true

        routeService.markStopCompleted(stop: stop, in: route) {
            self.isCompleting = false
            self.stop.completed = true
        }
    }
}

struct DriverStopView: View {

    @StateObject private var vm: DriverStopViewModel
    @ObservedObject private var session = DriverSession.shared

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
                    completeButton

                    Spacer(minLength: 40)
                }
                .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            DriverLocationManager.shared.startTracking(stopId: vm.stop.id)
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
    private var mapSection: some View {
        Map(coordinateRegion: .constant(
            MKCoordinateRegion(
                center: vm.stop.coordinate,
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
                          link: "https://whyteroutes.app/tracking/\(vm.stop.id ?? "")")
            }
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
        .disabled(vm.isCompleting || vm.stop.completed)
        .opacity(vm.stop.completed ? 0.4 : 1)
        .padding(.top, 10)
    }
}

