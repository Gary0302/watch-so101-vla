// watchOS-only adapters: Core Motion, haptic playback, WCSession.

#if os(watchOS)
import CoreMotion
import Foundation
import SO101Link
import SO101Protocol
import WatchConnectivity
import WatchKit

public final class MotionStreamer {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    public init() {
        queue.maxConcurrentOperationCount = 1
    }

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// Samples at ~50 Hz; WatchController's RateGate forwards ~20 Hz (SPEC §6.1).
    /// The handler runs on a background queue with the sample's own timestamp.
    public func start(_ handler: @escaping (_ q: [Double], _ gyro: [Double], _ gravity: [Double], _ t: TimeInterval) -> Void) {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 50.0
        // No magnetometer: only relative attitude to q0 is used, and yaw is ignored in v1.
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { motion, _ in
            guard let m = motion else { return }
            let q = m.attitude.quaternion
            handler([q.w, q.x, q.y, q.z],
                    [m.rotationRate.x, m.rotationRate.y, m.rotationRate.z],
                    [m.gravity.x, m.gravity.y, m.gravity.z],
                    m.timestamp)
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

public enum HapticPlayer {
    public static func play(_ style: HapticStyle) {
        let type: WKHapticType
        switch style {
        case .click: type = .click
        case .directionUp: type = .directionUp
        case .success: type = .success
        case .failure: type = .failure
        case .retry: type = .retry
        case .start: type = .start
        case .stop: type = .stop
        }
        WKInterfaceDevice.current().play(type)
    }
}

public final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    public var onFrame: ((LinkFrame) -> Void)?
    public var onReachable: ((Bool) -> Void)?
    /// Link traffic for the on-screen debug panel (motion is summarized as a rate).
    public let trace = LinkTrace()
    private let session = WCSession.default
    private let lock = NSLock()
    private var motionSent = 0, motionFailed = 0, motionDropped = 0
    private var motionSince = Date()

    public func start() {
        session.delegate = self
        session.activate()
    }

    public var isReachable: Bool { session.isReachable }

    /// Best effort; there is no queue for later (stale wrist poses are worthless).
    public func send(_ frame: LinkFrame) {
        if case .agent(let d) = frame, ProtocolCoder.messageType(of: d) == WatchMotion.messageType {
            return sendMotion(frame)
        }
        // Don't gate on isReachable: it can read false with the wrist down during a workout while
        // sendMessage still gets through. Try anyway; a real failure lands in the errorHandler.
        guard session.activationState == .activated else {
            trace.add("TX dropped (session not active): \(frame.summary)")
            return
        }
        let summary = frame.summary
        if case .voiceChunk = frame {} else { trace.add("TX \(summary)\(session.isReachable ? "" : " (unreachable?)")") }
        session.sendMessageData(frame.encoded(), replyHandler: { [weak self] reply in
            if let f = LinkFrame.decode(reply) { DispatchQueue.main.async { self?.onFrame?(f) } }
        }, errorHandler: { [weak self] error in
            self?.trace.add("TX FAIL \(summary): \(error.localizedDescription)")
        })
    }

    /// ~20 Hz: no reply handler (halves WCSession traffic), failures counted, not logged one by one.
    private func sendMotion(_ frame: LinkFrame) {
        guard session.activationState == .activated else {
            lock.withLock { motionDropped += 1 }
            return reportMotion()
        }
        lock.withLock {
            motionSent += 1
            if !session.isReachable { motionDropped += 1 }  // "dropped" now = sent while flagged unreachable
        }
        session.sendMessageData(frame.encoded(), replyHandler: nil) { [weak self] _ in
            self?.lock.withLock { self?.motionFailed += 1 }
        }
        reportMotion()
    }

    private func reportMotion() {
        let line: String? = lock.withLock {
            let dt = Date().timeIntervalSince(motionSince)
            guard dt >= 5 else { return nil }
            defer { motionSent = 0; motionFailed = 0; motionDropped = 0; motionSince = Date() }
            return String(format: "TX motion %.1f Hz, fail %d, unreach %d", Double(motionSent) / dt, motionFailed, motionDropped)
        }
        if let line { trace.add(line) }
    }

    private func receive(_ f: LinkFrame) {
        trace.add("RX \(f.summary)")
        DispatchQueue.main.async { self.onFrame?(f) }
    }

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let f = LinkFrame.decode(messageData) else { return trace.add("RX bad frame") }
        receive(f)
    }

    /// Latest link + status from the phone, delivered even when we were not reachable.
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyContext(applicationContext, source: "context")
    }

    private func applyContext(_ ctx: [String: Any], source: String) {
        guard let connected = ctx["agentConnected"] as? Bool else { return }
        trace.add("RX \(source): agent \(connected ? "up" : "DOWN")")
        DispatchQueue.main.async {
            self.onFrame?(.phoneLink(connected: connected))
            if connected, let status = ctx["status"] as? Data { self.onFrame?(.agent(status)) }
        }
    }

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        let r = session.isReachable
        trace.add("WC activated=\(activationState == .activated) reachable=\(r)\(error.map { " err \($0.localizedDescription)" } ?? "")")
        applyContext(session.receivedApplicationContext, source: "saved context")
        DispatchQueue.main.async { self.onReachable?(r) }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        let r = session.isReachable
        trace.add("phone \(r ? "reachable" : "UNREACHABLE")")
        DispatchQueue.main.async { self.onReachable?(r) }
    }
}
#endif
