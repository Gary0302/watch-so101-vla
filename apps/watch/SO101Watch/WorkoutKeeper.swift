// Keeps the app running, streaming and reachable with the wrist down / screen dimmed.
//
// Extended runtime sessions (self-care, mindfulness, physical-therapy) do not help: Apple
// says WCSession.isReachable is only true while the app is in the foreground or "running with
// a high priority in the background, for example during a workout session", and on a real
// watch the link dropped as soon as the screen dimmed. So: an HKWorkoutSession, nothing saved.
// Owned by WatchModel (app scope) so the delegate outlives any view.

import HealthKit
import SO101Link

@MainActor
final class WorkoutKeeper: NSObject, HKWorkoutSessionDelegate {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var authorized = false
    private let trace: LinkTrace

    init(trace: LinkTrace) {
        self.trace = trace
    }

    /// Starts a workout session if none is running. Call from the foreground.
    func ensure() async {
        guard HKHealthStore.isHealthDataAvailable() else { return trace.add("workout FAIL: no HealthKit") }
        if let s = session, s.state == .running || s.state == .prepared || s.state == .notStarted { return }
        if !authorized {
            do {
                try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
                authorized = true
            } catch {
                return trace.add("workout FAIL auth: \(error.localizedDescription)")
            }
        }
        if let s = session, s.state == .running { return }  // started while we awaited the prompt
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            s.delegate = self
            session = s
            s.startActivity(with: Date())
            trace.add("workout start requested")
        } catch {
            trace.add("workout FAIL: \(error.localizedDescription)")
        }
    }

    /// True while the workout keeps us running: then wrist-down / background is not "left the app".
    var isRunning: Bool { session?.state == .running }

    func stop() {
        session?.end()
        session = nil
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        trace.add("workout \(Self.name(fromState)) → \(Self.name(toState))")
        if toState == .ended || toState == .stopped {
            Task { @MainActor in if self.session === workoutSession { self.session = nil } }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        trace.add("workout FAIL: \(error.localizedDescription)")
        Task { @MainActor in if self.session === workoutSession { self.session = nil } }
    }

    nonisolated private static func name(_ s: HKWorkoutSessionState) -> String {
        switch s {
        case .notStarted: return "notStarted"
        case .running: return "RUNNING"
        case .ended: return "ended"
        case .paused: return "paused"
        case .prepared: return "prepared"
        case .stopped: return "stopped"
        @unknown default: return "state\(s.rawValue)"
        }
    }
}
