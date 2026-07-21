import SwiftUI

extension View {
    func onRouterRefresh(_ action: @escaping () -> Void) -> some View {
        self.onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppRouterRefresh"))) { _ in
            action()
        }
    }
}
