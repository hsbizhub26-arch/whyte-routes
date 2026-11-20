import Foundation
import Combine

/// Phase 5: how many stop updates are saved on the phone but not yet on
/// the server (no signal). Drives the "Saved on phone" badge on the
/// driver's stop screen. In-memory only: Firestore itself keeps the
/// queued writes across an app restart; this counter is just the badge.
@MainActor
final class PendingStopSync: ObservableObject {
    static let shared = PendingStopSync()
    @Published private(set) var count = 0

    func begin() { count += 1 }
    func finish() { count = max(0, count - 1) }
}

import SwiftUI

/// "Saved on phone - sends when signal returns", shown while any stop
/// update is still waiting for signal. Hidden otherwise.
struct SavedOnPhoneBadge: View {
    @ObservedObject private var pending = PendingStopSync.shared

    var body: some View {
        if pending.count > 0 {
            Label(pending.count == 1
                  ? "1 update saved on phone - sends when signal returns"
                  : "\(pending.count) updates saved on phone - send when signal returns",
                  systemImage: "icloud.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color("WRBlack").opacity(0.95))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
