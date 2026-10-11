// watchOS-only adapters: Core Motion, haptic playback, WCSession.

#if os(watchOS)
import CoreMotion
import Foundation
import SO101Link
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
    private let session = WCSession.default

    public func start() {
        session.delegate = self
        session.activate()
    }

    public var isReachable: Bool { session.isReachable }

    /// Best effort; there is no queue for later (stale wrist poses are worthless).
    public func send(_ frame: LinkFrame) {
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessageData(frame.encoded(), replyHandler: { [weak self] reply in
            if let f = LinkFrame.decode(reply) { DispatchQueue.main.async { self?.onFrame?(f) } }
        }, errorHandler: nil)
    }

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let f = LinkFrame.decode(messageData) else { return }
        DispatchQueue.main.async { self.onFrame?(f) }
    }

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        let r = session.isReachable
        DispatchQueue.main.async { self.onReachable?(r) }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        let r = session.isReachable
        DispatchQueue.main.async { self.onReachable?(r) }
    }
}
#endif
