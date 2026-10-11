// Watch-side haptic rendering policy (SPEC §7.3, §7.4).
//
// The agent already does edge detection and cooldowns. Here we only:
//   * map kinds to the fixed WKHapticType styles,
//   * drop duplicates (event_id) and stale events (beyond ttl_ms),
//   * keep the haptic engine's recovery gap, queueing one pending event by priority.
// Not playing a haptic never means the robot missed the event (SPEC §11.3).

import Foundation
import SO101Protocol

/// Mirrors WKHapticType without importing WatchKit, so the policy is testable anywhere.
public enum HapticStyle: Equatable, Sendable {
    case click, directionUp, success, failure, retry, start, stop
}

public extension HapticKind {
    var style: HapticStyle {
        switch self {
        case .nearLimit, .contactSuspected: return .click
        case .limitHit: return .directionUp
        case .graspLikely, .calibrationOK, .vlaFinished: return .success
        case .fault, .connectionLost, .graspLost: return .failure
        case .calibrationFailed: return .retry
        case .vlaStarted: return .start
        }
    }

    /// Same order as protocol.py HAPTIC_PRIORITY.
    var priority: Int {
        switch self {
        case .fault, .connectionLost: return 5
        case .vlaStarted, .vlaFinished, .calibrationOK, .calibrationFailed: return 4
        case .limitHit: return 3
        case .graspLikely, .graspLost: return 2
        case .contactSuspected: return 1
        case .nearLimit: return 0
        }
    }
}

/// One-way latency estimate without synchronized clocks: the smallest observed
/// (receive - created) is taken as the clock offset, and anything above it is delay.
public struct FreshnessEstimator: Sendable {
    private var samples: [Double] = []
    public let window: Int

    public init(window: Int = 64) {
        self.window = window
    }

    /// Returns the estimated delay in seconds for this event.
    public mutating func delay(createdMonoNs: Int64, receivedAt: TimeInterval) -> TimeInterval {
        let diff = receivedAt - Double(createdMonoNs) / 1e9
        samples.append(diff)
        if samples.count > window { samples.removeFirst() }
        return diff - samples.min()!
    }
}

public struct HapticScheduler: Sendable {
    public var minGap: TimeInterval = 0.3
    public var maxQueueAge: TimeInterval = 1.0
    private var freshness = FreshnessEstimator()
    private var seen: [String] = []
    private var lastPlay: TimeInterval = -.infinity
    private var queued: (event: HapticEvent, at: TimeInterval)?

    public init() {}

    /// Returns a style to play right now, if any.
    public mutating func receive(_ ev: HapticEvent, now: TimeInterval) -> HapticStyle? {
        guard !seen.contains(ev.eventId) else { return nil }
        seen.append(ev.eventId)
        if seen.count > 128 { seen.removeFirst() }

        let delay = freshness.delay(createdMonoNs: ev.createdMonoNs, receivedAt: now)
        guard ev.playHaptic, delay * 1000 <= Double(ev.ttlMs) else { return nil }

        if now - lastPlay >= minGap {
            lastPlay = now
            return ev.kind.style
        }
        if queued == nil || ev.kind.priority >= queued!.event.kind.priority {
            queued = (ev, now)
        }
        return nil
    }

    /// Call periodically (e.g. every 50 ms) to release a queued event once the gap has passed.
    public mutating func tick(now: TimeInterval) -> HapticStyle? {
        guard let q = queued else { return nil }
        if now - q.at > maxQueueAge {
            queued = nil
            return nil
        }
        guard now - lastPlay >= minGap else { return nil }
        queued = nil
        lastPlay = now
        return q.event.kind.style
    }
}
