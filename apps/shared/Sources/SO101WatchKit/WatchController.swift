// The Watch app's brain, platform-free: frames in, effects out.
//
// The Watch never decides robot state. It shows the agent's mode, stamps its
// requests with the epoch it is showing, and plays what the agent reports.

import Foundation
import SO101Link
import SO101Protocol
import SO101Voice

public enum WatchEffect: Equatable {
    case send(LinkFrame)
    case voice(VoiceCommand)
    case haptic(HapticStyle)
}

public struct WatchUI: Equatable, Sendable {
    public var mode: Mode = .disconnected
    public var epoch = 0
    public var phoneLinked = false
    public var agentLinked = false
    public var primaryLabel = "Not connected"
    public var primaryEnabled = false
    public var pending = false
    public var notice: String?
    public var lastHaptic: String?

    public init() {}
}

public final class WatchController {
    public static let source = "watch-primary-action"

    public private(set) var ui = WatchUI()
    public let sessionId: String
    public var intentTimeout: TimeInterval = 3.0

    private var haptics = HapticScheduler()
    private var voice = VoiceSession()
    private var seq = 0
    private var pendingRequest: (id: String, epoch: Int, at: TimeInterval)?
    private var motionGate = RateGate(hz: 20)

    public init(sessionId: String) {
        self.sessionId = sessionId
        refreshLabel()
    }

    // MARK: inputs

    public func onFrame(_ frame: LinkFrame, now: TimeInterval) -> [WatchEffect] {
        switch frame {
        case .phoneLink(let connected):
            ui.agentLinked = connected
            if !connected { ui.mode = .disconnected }
            refreshLabel()
            return connected ? [] : voice.onStatus(mode: .disconnected, epoch: ui.epoch).map(WatchEffect.voice)
        case .agent(let json):
            guard let msg = try? ProtocolCoder.decodeFromAgent(json) else { return [] }
            return onAgent(msg, now: now)
        case .voiceAck, .voiceChunk:
            return []
        }
    }

    public func onPhoneReachable(_ reachable: Bool) {
        ui.phoneLinked = reachable
        if !reachable { ui.agentLinked = false }
        refreshLabel()
    }

    /// Visible primary button, also bound to Double Tap via .handGestureShortcut(.primaryAction).
    public func onPrimaryAction(now: TimeInterval) -> [WatchEffect] {
        guard ui.primaryEnabled, pendingRequest == nil else { return [] }
        if ui.mode == .listening {
            return voice.onUserFinish().map(WatchEffect.voice)
        }
        return [sendIntent(.doubleTap, now: now)]
    }

    /// The STOP/HOLD touch button. Always allowed when the phone can hear us.
    public func onStop(now: TimeInterval) -> [WatchEffect] {
        guard ui.phoneLinked else { return [] }
        return [sendIntent(.stop, now: now)]
    }

    public func onMotion(quaternionWxyz: [Double], gyroRadS: [Double], gravityG: [Double],
                         sampleTime: TimeInterval) -> [WatchEffect] {
        guard ui.phoneLinked, motionGate.allow(sampleTime) else { return [] }
        seq += 1
        let m = WatchMotion(sessionId: sessionId, seq: seq, sampleMonoNs: Int64(sampleTime * 1e9),
                            quaternionWxyz: quaternionWxyz, gyroRadS: gyroRadS, gravityG: gravityG,
                            controlEpoch: ui.epoch)
        guard let data = try? ProtocolCoder.encode(m) else { return [] }
        return [.send(.agent(data))]
    }

    public func onLifecycle(active: Bool) -> [WatchEffect] {
        seq += 1
        let msg = WatchLifecycle(sessionId: sessionId, seq: seq, state: active ? .active : .inactive)
        var out: [WatchEffect] = []
        if let data = try? ProtocolCoder.encode(msg) { out.append(.send(.agent(data))) }
        if !active { out += voice.onStatus(mode: .hold, epoch: ui.epoch).map(WatchEffect.voice) }
        return out
    }

    public func onRecordingFinished(clipId: String, audio: Data?) -> [WatchEffect] {
        voice.onRecordingFinished(clipId: clipId, audio: audio).flatMap { cmd -> [WatchEffect] in
            guard case .send(let chunks) = cmd else { return [.voice(cmd)] }
            return chunks.compactMap { try? .send(.voiceChunk($0.encoded())) }
        }
    }

    public func tick(now: TimeInterval) -> [WatchEffect] {
        var out: [WatchEffect] = []
        if let p = pendingRequest, now - p.at > intentTimeout {
            pendingRequest = nil
            ui.pending = false
            ui.notice = "No response from robot"
            refreshLabel()
        }
        if let style = haptics.tick(now: now) { out.append(.haptic(style)) }
        return out
    }

    // MARK: internals

    private func onAgent(_ msg: FromAgent, now: TimeInterval) -> [WatchEffect] {
        var out: [WatchEffect] = []
        switch msg {
        case .status(let s):
            ui.mode = s.mode
            ui.epoch = s.controlEpoch
            ui.agentLinked = true
            // The agent moved on (every transition bumps the epoch): the request was handled
            // even if its ack got lost on the way.
            if let p = pendingRequest, s.controlEpoch > p.epoch {
                pendingRequest = nil
                ui.pending = false
            }
            out += voice.onStatus(mode: s.mode, epoch: s.controlEpoch).map(WatchEffect.voice)
        case .ack(let a):
            if a.requestId == pendingRequest?.id {
                pendingRequest = nil
                ui.pending = false
                ui.notice = a.result == .accepted || a.result == .duplicate ? nil : "\(a.result.rawValue): \(a.reason)"
            }
        case .haptic(let ev):
            ui.lastHaptic = ev.display
            if let style = haptics.receive(ev, now: now) { out.append(.haptic(style)) }
        case .error(let e):
            ui.notice = e.reason
        case .unknown:
            break
        }
        refreshLabel()
        return out
    }

    private func sendIntent(_ intent: Intent, now: TimeInterval) -> WatchEffect {
        let msg = ControlIntent(requestId: "w-\(UUID().uuidString.prefix(8))", sessionId: sessionId,
                                controlEpoch: ui.epoch, intent: intent, source: Self.source)
        pendingRequest = (msg.requestId, msg.controlEpoch, now)
        ui.pending = true
        ui.notice = nil
        refreshLabel()
        return .send(.agent((try? ProtocolCoder.encode(msg)) ?? Data()))
    }

    private func refreshLabel() {
        let (label, enabled): (String, Bool)
        if !ui.phoneLinked {
            (label, enabled) = ("iPhone unreachable", false)
        } else if !ui.agentLinked {
            (label, enabled) = ("Robot not connected", false)
        } else {
            switch ui.mode {
            case .manual: (label, enabled) = ("Calibrate & Talk", true)
            case .hold, .awaitRecalibration: (label, enabled) = ("Recalibrate to Take Over", true)
            case .listening: (label, enabled) = ("Finish Voice", true)
            case .vlaRunning: (label, enabled) = ("Interrupt VLA", true)
            case .calibrating: (label, enabled) = ("Hold wrist steady…", false)
            case .taskValidating: (label, enabled) = ("Checking task…", false)
            case .vlaCancelling: (label, enabled) = ("Stopping…", false)
            case .fault: (label, enabled) = ("Fault — robot holding", false)
            case .estopLatched: (label, enabled) = ("E-STOP latched", false)
            case .disconnected: (label, enabled) = ("Robot not connected", false)
            }
        }
        ui.primaryLabel = label
        ui.primaryEnabled = enabled && pendingRequest == nil
    }
}

/// Passes at most `hz` samples per second of sample time (CMDeviceMotion.timestamp).
public struct RateGate: Sendable {
    public let interval: TimeInterval
    private var next: TimeInterval = -.infinity

    public init(hz: Double) {
        interval = 1 / hz
    }

    /// Schedule-based so the average rate is `hz` even when the input rate is not a multiple of it.
    public mutating func allow(_ t: TimeInterval) -> Bool {
        guard t + 1e-6 >= next else { return false }
        next = next.isFinite && t - next < interval ? next + interval : t + interval
        return true
    }
}
