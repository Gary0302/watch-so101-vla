// Keeps the app running with the wrist down. Without this, watchOS suspends the app a few
// seconds after the screen dims: motion stops and the phone sees the watch as unreachable.
// A physical-therapy session (WKBackgroundModes) allows background motion for up to 1 h.

import WatchKit

@MainActor
final class RuntimeKeeper: NSObject, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?

    /// Starts a session if none is running. Must be called while the app is active.
    func ensure() {
        if let s = session, s.state == .running || s.state == .scheduled { return }
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        s.start()
        session = s
    }

    func stop() {
        session?.invalidate()
        session = nil
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        // A new session can only start from the foreground; the next ensure() (on activation) does it.
        Task { @MainActor in
            if self.session === extendedRuntimeSession { self.session = nil }
        }
    }
}
