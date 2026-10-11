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
    private lazy var keeper = RuntimeKeeper(trace: link.trace)
    private var timer: Timer?
    private var started = false

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
        keeper.ensure()
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
        // Last, so a pending permission prompt never delays the link or STOP button.
        // If denied, recordings fail and the agent rejects the task (fails closed).
        #if DEBUG
        if ProcessInfo.processInfo.environment["SO101_SKIP_PERMISSION_PROMPTS"] == "1" { return }
        #endif
        _ = await WatchClipRecorder.requestPermission()
    }

    func primaryAction() { runTapped { $0.onPrimaryAction(now: $1) } }
    func stop() { runTapped { $0.onStop(now: $1) } }

    /// A light click when a tap (or Double Tap) actually sent something, so you can feel it fired.
    private func runTapped(_ body: (WatchController, TimeInterval) -> [WatchEffect]) {
        let effects = body(controller, now)
        if effects.contains(where: { if case .send = $0 { return true } else { return false } }) {
            HapticPlayer.play(.click)
        } else if effects.isEmpty {
            link.trace.add("tap ignored: \(ui.primaryEnabled ? "request pending" : ui.primaryLabel)")
        }
        apply(effects)
    }
    func lifecycle(active: Bool) {
        if active { keeper.ensure() }
        apply(controller.onLifecycle(active: active))
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
