// Routing decisions for the iPhone relay, free of WatchConnectivity/URLSession so they are testable.

import Foundation
import SO101Protocol
import SO101Voice

public enum PhoneAction: Equatable {
    case relayMotion(Data)
    case relayIntent(Data)
    case relayReliable(Data)
    case replyToWatch(LinkFrame)
    case transcribe(AssembledClip)
    case drop(reason: String)
}

public final class PhoneRouter {
    public let assembler: ClipAssembler

    public init(assembler: ClipAssembler = ClipAssembler()) {
        self.assembler = assembler
    }

    /// A WCSession message from the Watch.
    public func fromWatch(_ raw: Data) -> [PhoneAction] {
        guard let frame = LinkFrame.decode(raw) else { return [.drop(reason: "bad_frame")] }
        switch frame {
        case .agent(let json):
            switch ProtocolCoder.messageType(of: json) {
            case WatchMotion.messageType: return [.relayMotion(json)]
            case ControlIntent.messageType: return [.relayIntent(json)]
            case WatchLifecycle.messageType: return [.relayReliable(json)]
            case let t: return [.drop(reason: "watch may not send \(t ?? "non-v1 message")")]
            }
        case .voiceChunk(let body):
            guard let chunk = try? VoiceChunk.decode(body) else { return [.drop(reason: "bad_chunk")] }
            let (ack, clip) = assembler.receive(chunk)
            var out: [PhoneAction] = []
            if let ackData = try? ack.encoded() { out.append(.replyToWatch(.voiceAck(ackData))) }
            if let clip { out.append(.transcribe(clip)) }
            return out
        case .voiceAck, .phoneLink:
            return [.drop(reason: "phone-bound frame type from watch")]
        }
    }

    /// Every agent message is forwarded to the Watch unchanged; the Watch shows status
    /// and plays haptics. Delivery is best effort (SPEC §11.3).
    public func fromAgent(_ json: Data) -> LinkFrame {
        .agent(json)
    }
}
