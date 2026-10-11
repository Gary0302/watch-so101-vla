// Wire protocol v1 (docs/SPEC.md §9). Mirrors robot/src/so101_watch/protocol.py;
// both sides are tested against the JSON in Tests/SO101ProtocolTests/Fixtures.

import Foundation

public let protocolVersion = 1

public enum Mode: String, Codable, Sendable {
    case disconnected = "DISCONNECTED"
    case hold = "HOLD"
    case manual = "MANUAL"
    case calibrating = "CALIBRATING"
    case listening = "LISTENING"
    case taskValidating = "TASK_VALIDATING"
    case vlaRunning = "VLA_RUNNING"
    case vlaCancelling = "VLA_CANCELLING"
    case awaitRecalibration = "AWAIT_RECALIBRATION"
    case fault = "FAULT"
    case estopLatched = "ESTOP_LATCHED"
}

public enum Owner: String, Codable, Sendable {
    case none = "NONE"
    case manual = "MANUAL"
    case vla = "VLA"
}

public enum Intent: String, Codable, Sendable {
    case doubleTap = "DOUBLE_TAP"
    case stop = "STOP"
    case resetFault = "RESET_FAULT"
}

public enum HapticKind: String, Codable, Sendable {
    case nearLimit = "NEAR_LIMIT"
    case limitHit = "LIMIT_HIT"
    case contactSuspected = "CONTACT_SUSPECTED"
    case graspLikely = "GRASP_LIKELY"
    case graspLost = "GRASP_LOST"
    case vlaStarted = "VLA_STARTED"
    case vlaFinished = "VLA_FINISHED"
    case fault = "FAULT"
    case connectionLost = "CONNECTION_LOST"
    case calibrationOK = "CALIBRATION_OK"
    case calibrationFailed = "CALIBRATION_FAILED"
}

/// A message with a fixed `type` tag in the envelope.
public protocol TypedMessage: Codable, Sendable {
    static var messageType: String { get }
}

// MARK: - Phone -> Agent

public struct WatchMotion: TypedMessage, Equatable {
    public static let messageType = "watch.motion"
    public var sessionId: String
    public var seq: Int
    /// Watch-local monotonic clock. Never subtract it from another device's clock.
    public var sampleMonoNs: Int64
    public var quaternionWxyz: [Double]
    public var gyroRadS: [Double]
    public var gravityG: [Double]
    public var controlEpoch: Int

    public init(sessionId: String, seq: Int, sampleMonoNs: Int64, quaternionWxyz: [Double],
                gyroRadS: [Double], gravityG: [Double], controlEpoch: Int) {
        self.sessionId = sessionId
        self.seq = seq
        self.sampleMonoNs = sampleMonoNs
        self.quaternionWxyz = quaternionWxyz
        self.gyroRadS = gyroRadS
        self.gravityG = gravityG
        self.controlEpoch = controlEpoch
    }
}

public struct WatchLifecycle: TypedMessage, Equatable {
    public static let messageType = "watch.lifecycle"
    public enum State: String, Codable, Sendable { case active, inactive }
    public var sessionId: String
    public var seq: Int
    public var state: State

    public init(sessionId: String, seq: Int, state: State) {
        self.sessionId = sessionId
        self.seq = seq
        self.state = state
    }
}

public struct ControlIntent: TypedMessage, Equatable {
    public static let messageType = "control.intent"
    public var requestId: String
    public var sessionId: String
    /// Must be the latest epoch from robot.status; otherwise the agent answers STALE_EPOCH (STOP excepted).
    public var controlEpoch: Int
    public var intent: Intent
    public var source: String

    public init(requestId: String, sessionId: String, controlEpoch: Int, intent: Intent, source: String) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.controlEpoch = controlEpoch
        self.intent = intent
        self.source = source
    }
}

public struct VoiceTranscript: TypedMessage, Equatable {
    public static let messageType = "voice.transcript"
    public var requestId: String
    public var sessionId: String
    public var controlEpoch: Int
    /// nil = nothing usable was heard. Sent as an explicit JSON null; the agent requires the key.
    public var text: String?

    public init(requestId: String, sessionId: String, controlEpoch: Int, text: String?) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.controlEpoch = controlEpoch
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case requestId, sessionId, controlEpoch, text }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(controlEpoch, forKey: .controlEpoch)
        try c.encode(text, forKey: .text)  // Optional -> null, never omitted
    }
}

// MARK: - Agent -> Phone

public struct HapticEvent: TypedMessage, Equatable {
    public static let messageType = "robot.haptic_event"
    public var eventId: String
    public var sessionId: String
    public var controlEpoch: Int
    public var kind: HapticKind
    public var severity: String
    public var confidence: Double
    public var ttlMs: Int
    public var display: String
    public var createdMonoNs: Int64
    /// false: update the UI text only (cooldown or a higher-priority event won).
    public var playHaptic: Bool
    public var axis: String?
    public var limitType: String?
    public var transactionId: Int?
    public var evidence: [String]
}

public struct RobotStatus: TypedMessage, Equatable {
    public static let messageType = "robot.status"
    public var sessionId: String
    public var controlEpoch: Int
    public var mode: Mode
    public var owner: Owner
    public var reason: String
    public var robotHolding: Bool
    public var vlaTaskId: String?
}

public struct ControlAck: TypedMessage, Equatable {
    public static let messageType = "control.ack"
    public enum Result: String, Codable, Sendable { case accepted, duplicate, ignored, rejected }
    public var requestId: String
    public var result: Result
    public var reason: String
    public var mode: Mode
    public var controlEpoch: Int
}

public struct ErrorMessage: TypedMessage, Equatable {
    public static let messageType = "error"
    public var reason: String
}

public enum FromAgent: Equatable, Sendable {
    case status(RobotStatus)
    case haptic(HapticEvent)
    case ack(ControlAck)
    case error(ErrorMessage)
    case unknown(type: String)
}

// MARK: - Coding

public enum ProtocolError: Error, Equatable {
    case unsupportedVersion(Int)
    case notAnObject
}

public enum ProtocolCoder {
    private struct Envelope: Decodable {
        let protocolVersion: Int
        let type: String
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// Body fields plus the `protocol_version` / `type` envelope, as one JSON object.
    public static func encode<T: TypedMessage>(_ message: T) throws -> Data {
        let body = try encoder().encode(message)
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ProtocolError.notAnObject
        }
        object["protocol_version"] = protocolVersion
        object["type"] = T.messageType
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func decodeFromAgent(_ data: Data) throws -> FromAgent {
        let d = decoder()
        let env = try d.decode(Envelope.self, from: data)
        guard env.protocolVersion == protocolVersion else {
            throw ProtocolError.unsupportedVersion(env.protocolVersion)
        }
        switch env.type {
        case RobotStatus.messageType: return .status(try d.decode(RobotStatus.self, from: data))
        case HapticEvent.messageType: return .haptic(try d.decode(HapticEvent.self, from: data))
        case ControlAck.messageType: return .ack(try d.decode(ControlAck.self, from: data))
        case ErrorMessage.messageType: return .error(try d.decode(ErrorMessage.self, from: data))
        default: return .unknown(type: env.type)
        }
    }
}
