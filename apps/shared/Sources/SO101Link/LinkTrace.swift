// A short, human-readable trail of link traffic for the on-screen debug panels.

import Foundation
import SO101Protocol

public extension LinkFrame {
    /// One line for a debug panel, e.g. "ack ignored ALREADY_HOLDING e1".
    var summary: String {
        switch self {
        case .phoneLink(let c): return c ? "phoneLink agent=up" : "phoneLink agent=DOWN"
        case .voiceChunk: return "voice chunk"
        case .voiceAck: return "voice ack"
        case .agent(let d): return LinkFrame.summarize(agentJSON: d)
        }
    }

    static func summarize(agentJSON d: Data) -> String {
        if let m = try? ProtocolCoder.decode(ControlIntent.self, from: d) {
            return "intent \(m.intent.rawValue) e\(m.controlEpoch)"
        }
        guard let msg = try? ProtocolCoder.decodeFromAgent(d) else {
            return ProtocolCoder.messageType(of: d) ?? "unknown (\(d.count) B)"
        }
        switch msg {
        case .status(let s): return "status \(s.mode.rawValue) e\(s.controlEpoch)"
        case .ack(let a): return "ack \(a.result.rawValue) \(a.reason) e\(a.controlEpoch)"
        case .haptic(let h): return "haptic \(h.kind.rawValue)"
        case .error(let e): return "error \(e.reason)"
        case .unknown(let type): return type
        }
    }
}

/// Ring buffer of timestamped lines. Thread-safe; read it from the UI with `lines`.
public final class LinkTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private let capacity: Int
    public var onChange: (() -> Void)?

    public init(capacity: Int = 40) {
        self.capacity = capacity
    }

    public func add(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "mm:ss.S"
        lock.withLock {
            buffer.append("\(f.string(from: Date())) \(line)")
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        }
        onChange?()
    }

    /// Newest first.
    public var lines: [String] { lock.withLock { buffer.reversed() } }
}
