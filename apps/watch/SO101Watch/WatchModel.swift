// Wires WatchController (pure logic) to the watchOS adapters. All controller calls happen on main.

import Foundation
import SO101Link
import SO101Protocol
import SO101Voice
import SO101WatchKit
import SwiftUI

@MainActor
final class WatchModel: ObservableObject {
    @Published private(set) var ui = WatchUI()
    @Published private(set) var recording = false
    @Published private(set) var debugLines: [String] = []

    private let controller = WatchController(sessionId: "watch-\(UUID().uuidString.prefix(8))")
    private let link = WatchLink()
    private let motion = MotionStreamer()
    private let recorder = WatchClipRecorder()
    private lazy var keeper = WorkoutKeeper(trace: link.trace)
    private var timer: Timer?
    private var started = false
    private var reportedActive = true

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() async {
        guard !started else { return }
        started = true

        link.onFrame = { [weak self] f in self?.run { $0.onFrame(f, now: $1) } }
        link.onReachable = { [weak self] r in
            guard let self else { return }
            controller.onPhoneReachable(r)
            ui = controller.ui
            // Announce ourselves; the phone answers with the current link + status.
            if r { apply(controller.onLifecycle(active: true)) }
        }
        link.trace.onChange = { [weak self] in
            DispatchQueue.main.async { self?.debugLines = self?.link.trace.lines ?? [] }
        }
        recorder.onFinished = { [weak self] id, audio in
            guard let self else { return }
            recording = false
            apply(controller.onRecordingFinished(clipId: id, audio: audio))
        }
        link.start()
        // CMDeviceMotion.timestamp is seconds since boot, same clock as systemUptime.
        motion.start { [weak self] q, gyro, gravity, t in
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(self.controller.onMotion(quaternionWxyz: q, gyroRadS: gyro, gravityG: gravity, sampleTime: t))
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run { $0.tick(now: $1) } }
        }
        // Last, so pending permission prompts never delay the link or STOP button.
        #if DEBUG
        if ProcessInfo.processInfo.environment["SO101_SKIP_PERMISSION_PROMPTS"] == "1" { return }
        #endif
        await keeper.ensure()  // HealthKit prompt the first time
        // If denied, recordings fail and the agent rejects the task (fails closed).
        _ = await WatchClipRecorder.requestPermission()
    }

    func primaryAction() { runTapped { $0.onPrimaryAction(now: $1) } }
    func stop() { runTapped { $0.onStop(now: $1) } }

    /// Every tap / Double Tap vibrates, so you always know it registered:
    /// click = acted on it, retry (double buzz) = ignored (reason in the debug trail).
    private func runTapped(_ body: (WatchController, TimeInterval) -> [WatchEffect]) {
        let before = controller.ui
        let effects = body(controller, now)
        if effects.isEmpty {
            HapticPlayer.play(.retry)
            link.trace.add("tap IGNORED: \(before.pending ? "waiting for previous reply" : before.primaryLabel)")
        } else {
            HapticPlayer.play(.click)
        }
        apply(effects)
    }
    func lifecycle(active: Bool, foreground: Bool) {
        if foreground, started { Task { await keeper.ensure() } }  // sessions start from the foreground only
        // Wrist down can drop us to .background even with the workout running. Never end the
        // workout here (that was the dim-screen disconnect) and don't report "inactive" while it
        // runs: motion keeps streaming, and if it ever stops the agent freezes/holds on its own.
        let running = keeper.isRunning
        let effective = active || running
        link.trace.add("app \(foreground ? "foreground" : active ? "dimmed (Always On)" : "BACKGROUND")"
                       + (running ? " · workout on" : " · workout OFF"))
        guard effective != reportedActive else { return }
        reportedActive = effective
        apply(controller.onLifecycle(active: effective))
    }

    private func run(_ body: (WatchController, TimeInterval) -> [WatchEffect]) {
        apply(body(controller, now))
    }

    private func apply(_ effects: [WatchEffect]) {
        for e in effects {
            switch e {
            case .send(let frame):
                link.send(frame)
            case .haptic(let style):
                HapticPlayer.play(style)
            case .voice(let cmd):
                handleVoice(cmd)
            }
        }
        if ui != controller.ui { ui = controller.ui }
    }

    private func handleVoice(_ cmd: VoiceCommand) {
        switch cmd {
        case .startRecording(let id, let maxDuration):
            do {
                try recorder.start(clipId: id, maxDuration: maxDuration)
                recording = true
            } catch {
                // Report "no audio" so the agent rejects the task instead of waiting for a timeout.
                apply(controller.onRecordingFinished(clipId: id, audio: nil))
            }
        case .stopRecording:
            recorder.stop()
        case .discard:
            recorder.discard()
            recording = false
        case .send(let chunks):
            for c in chunks { if let d = try? c.encoded() { link.send(.voiceChunk(d)) } }
        }
    }
}
