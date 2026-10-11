// Framing for WCSession.sendMessageData between Watch and iPhone.
//
// One tag byte, then the payload:
//   0x01  agent protocol JSON (same bytes as on the WSS link; the phone relays them)
//   0x02  voice chunk (binary plist, SO101Voice.VoiceChunk)
//   0x03  voice chunk ack
//   0x04  link status from the phone (connected to agent or not)

import Foundation

public enum LinkFrame: Equatable, Sendable {
    case agent(Data)
    case voiceChunk(Data)
    case voiceAck(Data)
    case phoneLink(connected: Bool)

    public func encoded() -> Data {
        switch self {
        case .agent(let d): return Data([0x01]) + d
        case .voiceChunk(let d): return Data([0x02]) + d
        case .voiceAck(let d): return Data([0x03]) + d
        case .phoneLink(let c): return Data([0x04, c ? 1 : 0])
        }
    }

    public static func decode(_ data: Data) -> LinkFrame? {
        guard let tag = data.first else { return nil }
        let body = data.dropFirst()
        switch tag {
        case 0x01: return .agent(Data(body))
        case 0x02: return .voiceChunk(Data(body))
        case 0x03: return .voiceAck(Data(body))
        case 0x04: return body.count == 1 ? .phoneLink(connected: body.first == 1) : nil
        default: return nil
        }
    }
}
