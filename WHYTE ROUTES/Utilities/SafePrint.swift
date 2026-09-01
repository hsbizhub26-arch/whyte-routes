import Foundation

/// DEBUG-only console logging for anything that interpolates a real
/// person's data: an email address, a Firebase uid, a phone number, a
/// customer or company name, a company id, or a subscription tier.
///
/// `print` is not free in a shipped build. It writes to stderr, which
/// on a real device lands in the system log - readable over a cable,
/// readable by anything holding the OSLogStore entitlement, and baked
/// into any sysdiagnose a user attaches to a support ticket. Every
/// owner email, uid and company name this app logged was going
/// straight there, on every TestFlight and App Store build.
///
/// The message is an `@autoclosure` on purpose: in Release the body
/// compiles away, so the interpolation is never evaluated at all. The
/// call site does no work rather than building the string containing
/// the uid and then throwing it away.
///
/// This is deliberately NOT a blanket replacement for `print`. Logs
/// that name nobody - a Firestore permission denial, a StoreKit
/// failure, an audio-session error, a route or stop id - stay as plain
/// `print`, because the device console is the only diagnostic we get
/// back from a driver in the field and silencing it would leave us
/// blind. Reach for this only where a value belonging to an actual
/// person is interpolated into the message.
///
/// The `[WR DEBUG]` prefix is kept so that it is obvious while reading
/// a simulator log which lines will not exist in a shipped build, and
/// therefore which ones cannot be relied on for field support.
func safePrint(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[WR DEBUG]:", message())
    #endif
}
