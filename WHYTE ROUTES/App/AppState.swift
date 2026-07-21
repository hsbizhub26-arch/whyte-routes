import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var lastTab: String = "dashboard"
    @Published var showSidebar: Bool = false
    @Published var showTracking: Bool = false
    @Published var currentTrackingId: String = ""
}
