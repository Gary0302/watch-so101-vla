// Reliable delivery for control intents (SPEC §9.4): resend until ACK, then give up visibly.
//
// Resending is safe because the agent deduplicates on request_id. A resend keeps
// the original control_epoch, so a tap that was meant for an old mode is still
// rejected as STALE_EPOCH rather than reinterpreted.

import Foundation
import SO101Protocol

public final class IntentTracker {
    public struct Pending: Equatable {
        public let intent: ControlIntent
        public let firstSent: Date
        public var lastSent: Date
        public var attempts: Int
    }

    public enum Outcome: Equatable {
        case acked(ControlAck)
        case gaveUp(ControlIntent)
    }

    public let resendInterval: TimeInterval
    public let giveUpAfter: TimeInterval
    private(set) public var pending: [String: Pending] = [:]
    private var counter = 0

    public init(resendInterval: TimeInterval = 0.3, giveUpAfter: TimeInterval = 3.0) {
        self.resendInterval = resendInterval
        self.giveUpAfter = giveUpAfter
    }

    public func make(_ intent: Intent, sessionId: String, epoch: Int, source: String, now: Date) -> ControlIntent {
        counter += 1
        let msg = ControlIntent(requestId: "c-\(UUID().uuidString.prefix(8))-\(counter)", sessionId: sessionId,
                                controlEpoch: epoch, intent: intent, source: source)
        track(msg, now: now)
        return msg
    }

    /// Track an intent built elsewhere (the Watch stamps the epoch its UI was showing).
    public func track(_ msg: ControlIntent, now: Date) {
        guard pending[msg.requestId] == nil else { return }
        pending[msg.requestId] = Pending(intent: msg, firstSent: now, lastSent: now, attempts: 1)
    }

    /// Intents to resend now, plus outcomes for ones that timed out.
    public func tick(now: Date) -> (resend: [ControlIntent], outcomes: [Outcome]) {
        var resend: [ControlIntent] = []
        var outcomes: [Outcome] = []
        for (id, var p) in pending {
            if now.timeIntervalSince(p.firstSent) >= giveUpAfter {
                pending[id] = nil
                outcomes.append(.gaveUp(p.intent))
            } else if now.timeIntervalSince(p.lastSent) >= resendInterval {
                p.lastSent = now
                p.attempts += 1
                pending[id] = p
                resend.append(p.intent)
            }
        }
        return (resend.sorted { $0.requestId < $1.requestId }, outcomes)
    }

    public func receive(_ ack: ControlAck) -> Outcome? {
        guard pending.removeValue(forKey: ack.requestId) != nil else { return nil }
        return .acked(ack)
    }
}

/// Latest-only slot for motion frames (SPEC §9.4): never queue stale wrist poses.
public struct LatestOnly<T> {
    private var value: T?
    public var dropped = 0

    public init() {}

    public mutating func put(_ v: T) {
        if value != nil { dropped += 1 }
        value = v
    }

    public mutating func take() -> T? {
        defer { value = nil }
        return value
    }
}
